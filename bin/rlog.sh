#!/usr/bin/env bash
# Host resource sampler for dssh rlog. Survives container restarts: docker
# failures are logged and skipped, never fatal. Fsyncs so a hard reset keeps
# the last ticks.
set -u

out_dir="${DSSH_RLOG_DIR:-.}"
interval="${DSSH_RLOG_INTERVAL:-1}"
targets="${DSSH_RLOG_TARGETS:-}"
max_bytes="${DSSH_RLOG_HISTORY_MAX_BYTES:-16777216}"
keep_plain="${DSSH_RLOG_HISTORY_KEEP_PLAIN:-3}"
archive_max="${DSSH_RLOG_ARCHIVE_MAX_BYTES:-268435456}"
compress_pid=""
compress_file=""
mkdir -p "$out_dir"

latest="$out_dir/latest.txt"
history="$out_dir/history.log"
tmp="$out_dir/.latest.tmp"
pidfile="$out_dir/rlog.pid"
stats_file="$out_dir/.docker-stats.stream"
stats_pid=""
stats_key=""
gpu_cache="n/a"
gpu_skip_until=0
docker_skip_until=0
docker_skip_status="docker busy"
cpu_prev_idle=""
cpu_prev_total=""
nproc_count="$(nproc 2>/dev/null || echo 1)"

printf '%s\n' "$$" > "$pidfile"

now_s() {
  if [[ -n "${EPOCHREALTIME-}" ]]; then
    printf '%s' "$EPOCHREALTIME"
  else
    date +%s.%N
  fi
}

sleep_remaining() {
  local start="$1" remain
  remain="$(awk -v s="$start" -v i="$interval" -v n="$(now_s)" 'BEGIN {
    r = i - (n - s)
    if (r < 0.05) r = 0
    printf "%.3f", r
  }')"
  if awk -v r="$remain" 'BEGIN { exit !(r > 0) }'; then
    sleep "$remain" || true
  fi
}

docker_lock_path() {
  printf '%s\n' "${XDG_RUNTIME_DIR:-/tmp}/dssh-docker.lock"
}

cli_pid_file() {
  printf '%s\n' "$out_dir/.docker-cli.pid"
}

read_cli_pid() {
	local f
	f="$(cli_pid_file)"
	[[ -f "$f" ]] || return 0
	tr -d '[:space:]' < "$f" 2>/dev/null || true
}

rlog_cli_stuck() {
  local pid
  pid="$(read_cli_pid)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  if pgrep -P $$ -f 'docker inspect' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

docker_graph_busy() {
  local lock
  lock="$(docker_lock_path)"
  : >>"$lock"
  if flock -n "$lock" true 2>/dev/null; then
    return 1
  fi
  return 0
}

reap_orphan_stats() {
  local pid rest ppid
  while read -r pid rest; do
    [[ -z "$pid" || "$pid" == "$$" || "$pid" == "${stats_pid:-}" ]] && continue
    [[ "$rest" == *"docker stats --format"* ]] || continue
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$ppid" == "$$" || "$ppid" == "1" ]]; then
      kill "$pid" 2>/dev/null || true
      kill -9 "$pid" 2>/dev/null || true
    fi
  done < <(pgrep -af 'docker stats --format' 2>/dev/null || true)
}

stop_stats_stream() {
  if [[ -n "${stats_pid:-}" ]]; then
    kill "$stats_pid" 2>/dev/null || true
    kill -9 "$stats_pid" 2>/dev/null || true
    wait "$stats_pid" 2>/dev/null || true
  fi
  stats_pid=""
  stats_key=""
  reap_orphan_stats
}

trap 'stop_stats_stream' EXIT INT TERM
reap_orphan_stats

# Fast path for `docker inspect` only. Stats come from the background stream.
# Skip while dssh holds the graph lock, and do not start another inspect if
# the last one is still alive.
docker_cli() {
  local rc=0 child docker_cli_pid
  if rlog_cli_stuck; then
    return 124
  fi
  if docker_graph_busy; then
    return 124
  fi
  rm -f "$(cli_pid_file)"
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground -k 0.3 1 docker "$@" &
    docker_cli_pid=$!
    printf '%s\n' "$docker_cli_pid" > "$(cli_pid_file)"
    wait "$docker_cli_pid" || rc=$?
    child="$(pgrep -P "$docker_cli_pid" 2>/dev/null | head -n1 || true)"
    if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null; then
      printf '%s\n' "$child" > "$(cli_pid_file)"
      docker_cli_pid=""
      return 124
    fi
    if kill -0 "$docker_cli_pid" 2>/dev/null; then
      return 124
    fi
    rm -f "$(cli_pid_file)"
    docker_cli_pid=""
    return "$rc"
  fi
  docker "$@"
}

trim_stats_stream() {
  local size tmp
  size="$(stat -c%s "$stats_file" 2>/dev/null || echo 0)"
  if [[ "$size" -lt 262144 ]]; then
    return 0
  fi
  tmp="$stats_file.trim"
  tail -c 65536 "$stats_file" >"$tmp" 2>/dev/null || return 0
  cat "$tmp" >"$stats_file"
  rm -f "$tmp"
}

# One `docker stats` covers every live container. Keep a single writer process
# and let the 1s snapshot loop only read the file.
ensure_stats_stream() {
  local key="$1"
  shift
  if docker_graph_busy; then
    stop_stats_stream
    return 0
  fi
  if [[ -n "$stats_pid" ]] && kill -0 "$stats_pid" 2>/dev/null && [[ "$stats_key" == "$key" ]]; then
    trim_stats_stream
    return 0
  fi
  stop_stats_stream
  stats_key="$key"
  : > "$stats_file"
  if [[ $# -eq 0 || "$key" == "none" ]]; then
    return 0
  fi
  docker stats --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}' "$@" \
    >>"$stats_file" 2>/dev/null &
  stats_pid=$!
}

latest_stats_line() {
  local n="$1"
  [[ -f "$stats_file" ]] || return 0
  tail -n 80 "$stats_file" | awk -F'|' -v n="$n" '{
    gsub(/\033\[[0-9;?]*[A-Za-z]/, "")
    gsub(/\r/, "")
    if (NF < 7) next
    if ($2 == "--" || $2 == "" || $3 ~ /^--/) next
    if ($1 == n) line = $0
  } END { if (line != "") print line }'
}

sample_gpu() {
  local now gpu
  now="${EPOCHSECONDS:-$(date +%s)}"
  if (( now < gpu_skip_until )); then
    printf '%s' "$gpu_cache"
    return 0
  fi
  gpu=""
  if command -v timeout >/dev/null 2>&1; then
    gpu="$(timeout 0.3 nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader 2>/dev/null | head -n1 || true)"
  else
    gpu="$(nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$gpu" || "$gpu" == *"failed"* || "$gpu" == *"NVIDIA-SMI"* ]]; then
    gpu_cache="n/a"
    gpu_skip_until=$((now + 30))
  else
    gpu_cache="$gpu"
    gpu_skip_until=$((now + 1))
  fi
  printf '%s' "$gpu_cache"
}

fsync_file() {
  local path="$1"
  if sync -d "$path" 2>/dev/null; then
    return 0
  fi
  sync "$path" 2>/dev/null || sync || true
}

rotate_history_if_needed() {
  local size stamp dest n
  if [[ -f "$history" ]]; then
    size="$(stat -c%s "$history" 2>/dev/null || echo 0)"
    if [[ "$size" -ge "$max_bytes" ]]; then
      fsync_file "$history"
      stamp="$(date +%Y-%m-%dT%H%M%S)"
      dest="$out_dir/history-$stamp.log"
      n=1
      while [[ -e "$dest" || -e "$dest.xz" || -e "$dest.gz" || -e "$dest.zst" ]]; do
        dest="$out_dir/history-$stamp-$n.log"
        n=$((n + 1))
      done
      mv -f "$history" "$dest" 2>/dev/null || true
    fi
  fi
  manage_history_archives
}

rotated_plain_logs() {
  compgen -G "$out_dir/history-*.log" 2>/dev/null | sort
}

history_archive_files() {
  {
    compgen -G "$out_dir/history-*.log" || true
    compgen -G "$out_dir/history-*.log.xz" || true
    compgen -G "$out_dir/history-*.log.gz" || true
    compgen -G "$out_dir/history-*.log.zst" || true
  } 2>/dev/null | sort
}

file_bytes() {
  stat -c%s "$1" 2>/dev/null || echo 0
}

history_on_disk_bytes() {
  local total=0 f
  if [[ -f "$history" ]]; then
    total=$((total + $(file_bytes "$history")))
  fi
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] || continue
    total=$((total + $(file_bytes "$f")))
  done < <(history_archive_files)
  printf '%s' "$total"
}

compress_is_running() {
  [[ -n "${compress_pid:-}" ]] && kill -0 "$compress_pid" 2>/dev/null
}

start_compress_history() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if compress_is_running; then
    return 0
  fi
  compress_file="$f"
  if command -v xz >/dev/null 2>&1; then
    nice -n 19 xz -9e -T1 -q -- "$f" &
  elif command -v zstd >/dev/null 2>&1; then
    nice -n 19 zstd --ultra -22 --rm -q -- "$f" &
  else
    nice -n 19 gzip -9 -- "$f" &
  fi
  compress_pid=$!
  disown "$compress_pid" 2>/dev/null || true
}

manage_history_archives() {
  local files=() f i count keep_n total
  keep_n="$keep_plain"
  if ! [[ "$keep_n" =~ ^[0-9]+$ ]]; then
    keep_n=3
  fi
  if compress_is_running; then
    :
  else
    compress_pid=""
    compress_file=""
    while IFS= read -r f; do
      [[ -n "$f" && -f "$f" ]] || continue
      files+=("$f")
    done < <(rotated_plain_logs)
    count="${#files[@]}"
    if (( count > keep_n )); then
      start_compress_history "${files[0]}"
    fi
  fi

  total="$(history_on_disk_bytes)"
  if ! [[ "$archive_max" =~ ^[0-9]+$ ]]; then
    archive_max=268435456
  fi
  if [[ "$total" -le "$archive_max" ]]; then
    return 0
  fi

  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] || continue
    [[ "$f" == "$compress_file" ]] && continue
    rm -f "$f" 2>/dev/null || true
    total="$(history_on_disk_bytes)"
    if [[ "$total" -le "$archive_max" ]]; then
      return 0
    fi
  done < <(history_archive_files | grep -E '\.(xz|gz|zst)$' || true)

  files=()
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] || continue
    files+=("$f")
  done < <(rotated_plain_logs)
  count="${#files[@]}"
  if (( count <= keep_n )); then
    return 0
  fi
  for (( i = 0; i < count - keep_n; i++ )); do
    f="${files[i]}"
    [[ "$f" == "$compress_file" ]] && continue
    rm -f "$f" 2>/dev/null || true
    total="$(history_on_disk_bytes)"
    if [[ "$total" -le "$archive_max" ]]; then
      return 0
    fi
  done
}

psi_avg10() {
  local file="$1"
  awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^avg10=/) {
        split($i, a, "=")
        print a[2]
        exit
      }
    }
  }' "$file" 2>/dev/null || echo n/a
}

fmt_pct() {
  if [[ "${1:-}" == "n/a" || -z "${1:-}" ]]; then
    printf '%7s' "n/a"
  else
    printf '%6s%%' "$1"
  fi
}

pct_bar() {
  awk -v p="${1:-0}" -v w="${2:-10}" 'BEGIN {
    if (p == "" || p == "n/a" || p == "-") {
      fill = ""
      for (i = 0; i < w; i++) fill = fill "-"
      printf "[%s]", fill
      exit
    }
    x = p + 0
    if (x < 0) x = 0
    n = int(x * w / 100 + 0.5)
    if (n == 0 && x >= 1) n = 1
    if (n > w) n = w
    fill = ""
    empty = ""
    for (i = 0; i < n; i++) fill = fill "#"
    for (; i < w; i++) empty = empty "-"
    printf "[%s%s]", fill, empty
  }'
}

host_cpu_pct() {
  local user nice system idle iowait irq softirq steal rest
  local idle_all nonidle total d_total d_idle
  read -r _ user nice system idle iowait irq softirq steal rest < /proc/stat
  idle_all=$((idle + iowait))
  nonidle=$((user + nice + system + irq + softirq + steal))
  total=$((idle_all + nonidle))
  if [[ -z "${cpu_prev_total:-}" || "$cpu_prev_total" -eq 0 ]]; then
    cpu_prev_idle="$idle_all"
    cpu_prev_total="$total"
    HOST_CPU_PCT="n/a"
    return 0
  fi
  d_total=$((total - cpu_prev_total))
  d_idle=$((idle_all - cpu_prev_idle))
  cpu_prev_idle="$idle_all"
  cpu_prev_total="$total"
  if (( d_total <= 0 )); then
    HOST_CPU_PCT="0.0"
    return 0
  fi
  HOST_CPU_PCT="$(awk -v dt="$d_total" -v di="$d_idle" 'BEGIN { printf "%.1f", (dt - di) * 100 / dt }')"
}

host_mem_swap_pct() {
  awk '
    /^MemTotal:/ { mt = $2 }
    /^MemAvailable:/ { ma = $2 }
    /^SwapTotal:/ { st = $2 }
    /^SwapFree:/ { sf = $2 }
    END {
      mem = (mt > 0) ? (mt - ma) * 100 / mt : 0
      swap = (st > 0) ? (st - sf) * 100 / st : 0
      printf "%.1f %.1f %d\n", mem, swap, mt * 1024
    }
  ' /proc/meminfo 2>/dev/null || echo "n/a n/a 0"
}

summarize_container_stats() {
  local host_mem_bytes="$1"
  awk -F'|' -v nproc="$nproc_count" -v hostmem="$host_mem_bytes" '
    function tobytes(s,   n, u) {
      gsub(/[ \t]/, "", s)
      if (s == "" || s == "-") return 0
      n = s + 0
      u = s
      sub(/^[0-9.]+/, "", u)
      if (u == "B" || u == "") return n
      if (u == "kB" || u == "KB") return n * 1000
      if (u == "MB") return n * 1000 * 1000
      if (u == "GB") return n * 1000 * 1000 * 1000
      if (u == "TB") return n * 1000 * 1000 * 1000 * 1000
      if (u == "k" || u == "KiB") return n * 1024
      if (u == "MiB") return n * 1024 * 1024
      if (u == "GiB") return n * 1024 * 1024 * 1024
      if (u == "TiB") return n * 1024 * 1024 * 1024 * 1024
      return n
    }
    function iec(b) {
      if (b >= 1024*1024*1024) return sprintf("%.1fGiB", b / (1024*1024*1024))
      if (b >= 1024*1024) return sprintf("%.1fMiB", b / (1024*1024))
      if (b >= 1024) return sprintf("%.1fKiB", b / 1024)
      return sprintf("%dB", b)
    }
    function si(b) {
      if (b >= 1e9) return sprintf("%.1fGB", b / 1e9)
      if (b >= 1e6) return sprintf("%.1fMB", b / 1e6)
      if (b >= 1e3) return sprintf("%.1fkB", b / 1e3)
      return sprintf("%dB", b)
    }
    {
      gsub(/%/, "", $2)
      gsub(/%/, "", $4)
      cpu += $2 + 0
      split($3, m, "/")
      mem += tobytes(m[1])
      split($5, n, "/")
      netr += tobytes(n[1]); nett += tobytes(n[2])
      split($6, b, "/")
      blkr += tobytes(b[1]); blkw += tobytes(b[2])
      pids += $7 + 0
    }
    END {
      memp = (hostmem > 0) ? mem * 100 / hostmem : 0
      cpus = (nproc > 0) ? cpu / nproc : cpu
      printf "%.2f%%|%s / %s|%.2f%%|%s / %s|%s / %s|%d|%.2f\n", \
        cpu, iec(mem), iec(hostmem), memp, si(netr), si(nett), si(blkr), si(blkw), pids, cpus
    }
  '
}

print_capacity() {
  local apps_cpu_host="${1:-0}" apps_mem_pct="${2:-0}" apps_pids="${3:-0}"
  local cpu_pct mem_pct swap_pct disk_pct load1 mem_swap
  host_cpu_pct
  cpu_pct="${HOST_CPU_PCT:-n/a}"
  mem_swap="$(host_mem_swap_pct)"
  mem_pct="${mem_swap%% *}"
  swap_pct="$(printf '%s\n' "$mem_swap" | awk '{print $2}')"
  disk_pct="$(df -P / 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); printf "%.1f", $5 }')"
  load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo n/a)"
  echo "CAPACITY"
  printf '  host  cpu %s %s  mem %s %s  disk %s %s  swap %s\n' \
    "$(fmt_pct "$cpu_pct")" "$(pct_bar "$cpu_pct")" \
    "$(fmt_pct "$mem_pct")" "$(pct_bar "$mem_pct")" \
    "$(fmt_pct "${disk_pct:-n/a}")" "$(pct_bar "${disk_pct:-0}")" \
    "$(fmt_pct "$swap_pct")"
  printf '  apps  cpu %s %s  mem %s %s  pids %-5s  load %s / %s cpus\n' \
    "$(fmt_pct "$apps_cpu_host")" "$(pct_bar "$apps_cpu_host")" \
    "$(fmt_pct "$apps_mem_pct")" "$(pct_bar "$apps_mem_pct")" \
    "$apps_pids" \
    "$load1" "$nproc_count"
  echo
}

sample_system() {
  local stamp="${1:-$(date -Is)}"
  local mem_line swap_line disk gpu dirty
  mem_line="$(free -h 2>/dev/null | awk '/^Mem:/{printf "%s used / %s  avail %s", $3, $2, $7}')"
  swap_line="$(free -h 2>/dev/null | awk '/^Swap:/{printf "%s / %s", $3, $2}')"
  dirty="$(awk '/^Dirty:/{printf "%.1fMi", $2/1024}' /proc/meminfo 2>/dev/null || echo n/a)"
  disk="$(df -h / 2>/dev/null | awk 'NR==2{printf "%s used / %s (%s)", $3, $2, $5}')"
  gpu="$(sample_gpu)"

  local mem_pct swap_pct mem_swap
  mem_swap="$(host_mem_swap_pct)"
  mem_pct="$(printf '%s\n' "$mem_swap" | awk '{print $1}')"
  swap_pct="$(printf '%s\n' "$mem_swap" | awk '{print $2}')"
  echo "HOST"
  printf '  time   %s\n' "$stamp"
  printf '  load   %s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo n/a)"
  printf '  mem    %s%%  %s  dirty %s\n' "${mem_pct:-n/a}" "${mem_line:-n/a}" "$dirty"
  printf '  swap   %s%%  %s\n' "${swap_pct:-n/a}" "${swap_line:-n/a}"
  printf '  psi    cpu %s  mem %s  io %s\n' \
    "$(psi_avg10 /proc/pressure/cpu)" \
    "$(psi_avg10 /proc/pressure/memory)" \
    "$(psi_avg10 /proc/pressure/io)"
  printf '  disk   %s\n' "${disk:-n/a}"
  printf '  gpu    %s\n' "$gpu"
  printf '  fds    %s open\n' "$(awk '{print $1}' /proc/sys/fs/file-nr 2>/dev/null || echo n/a)"
  echo
  echo "TOP RSS"
  printf '  %-7s %8s %6s %6s  %s\n' PID RSS CPU% MEM% COMM
  ps -eo pid,rss,pcpu,pmem,comm --sort=-rss 2>/dev/null \
    | awk 'NR>1 && NR<=9 {printf "  %-7s %7sk %5s%% %5s%%  %s\n", $1, $2, $3, $4, $5}'
  echo
  local kernel
  if command -v timeout >/dev/null 2>&1; then
    kernel="$(timeout -k 0.2 0.4 dmesg -T --level=err,warn 2>/dev/null | tail -n 8 || true)"
  else
    kernel="$(dmesg -T --level=err,warn 2>/dev/null | tail -n 8 || true)"
  fi
  echo "KERNEL"
  if [[ -n "$kernel" ]]; then
    printf '%s\n' "$kernel" | sed 's/^/  /'
  else
    echo "  none"
  fi
  echo
}

sample_containers() {
  if [[ -z "$targets" ]]; then
    print_capacity 0 0 0
    echo "CONTAINERS"
    echo "  (none configured — set dssh_rlog_containers)"
    echo
    return 0
  fi

  local live=() names=() aliases=() statuses=() inspect_names=()
  local pair alias name alt inspect_out inspect_err inspect_rc default_status now
  IFS=',' read -ra pairs <<< "$targets"
  for pair in "${pairs[@]}"; do
    pair="${pair#"${pair%%[![:space:]]*}"}"
    pair="${pair%"${pair##*[![:space:]]}"}"
    [[ -z "$pair" ]] && continue
    alias="${pair%%=*}"
    name="${pair#*=}"
    [[ -z "$name" ]] && name="$alias"
    alt="dssh-${alias}-start"
    aliases+=("$alias")
    names+=("$name")
    statuses+=("pending")
    inspect_names+=("$name")
    if [[ "$alt" != "$name" ]]; then
      inspect_names+=("$alt")
    fi
  done

  inspect_out=""
  inspect_err=""
  inspect_rc=0
  default_status="not running"
  now="${EPOCHSECONDS:-$(date +%s)}"
  if (( now < docker_skip_until )) || docker_graph_busy || rlog_cli_stuck; then
    default_status="$docker_skip_status"
    ensure_stats_stream none
  elif [[ ${#inspect_names[@]} -gt 0 ]]; then
    docker_cli inspect --type container -f '{{.Name}} {{.State.Status}}' "${inspect_names[@]}" \
      >"$out_dir/.inspect.out" 2>"$out_dir/.inspect.err" || inspect_rc=$?
    inspect_out="$(cat "$out_dir/.inspect.out" 2>/dev/null || true)"
    inspect_err="$(cat "$out_dir/.inspect.err" 2>/dev/null || true)"
    if [[ "$inspect_rc" -eq 124 ]]; then
      default_status="docker busy"
      docker_skip_status="docker busy"
      docker_skip_until=$((now + 8))
      ensure_stats_stream none
    elif [[ "$inspect_err" == *'Cannot connect'* || "$inspect_err" == *'error during connect'* || "$inspect_err" == *'Is the docker daemon running'* ]]; then
      default_status="docker down"
      docker_skip_status="docker down"
      docker_skip_until=$((now + 8))
      ensure_stats_stream none
    fi
  fi

  local i found_name found_status
  for i in "${!aliases[@]}"; do
    name="${names[$i]}"
    alt="dssh-${aliases[$i]}-start"
    found_name=""
    found_status=""
    statuses[$i]="$default_status"
    if [[ -n "$inspect_out" ]]; then
      found_status="$(printf '%s\n' "$inspect_out" | awk -v n="/$name" -v n2="$name" '
        $1==n || $1==n2 || substr($1,2)==n2 { print $2; exit }
      ')"
      if [[ -n "$found_status" ]]; then
        found_name="$name"
      elif [[ "$alt" != "$name" ]]; then
        found_status="$(printf '%s\n' "$inspect_out" | awk -v n="/$alt" -v n2="$alt" '
          $1==n || $1==n2 || substr($1,2)==n2 { print $2; exit }
        ')"
        if [[ -n "$found_status" ]]; then
          found_name="$alt"
        fi
      fi
    fi
    if [[ -n "$found_name" ]]; then
      names[$i]="$found_name"
      statuses[$i]="$found_status"
      if [[ "$found_status" == "running" ]]; then
        live+=("$found_name")
      fi
    fi
  done

  local stats="" line
  if [[ ${#live[@]} -gt 0 ]]; then
    ensure_stats_stream "${live[*]}" "${live[@]}"
    for name in "${live[@]}"; do
      line="$(latest_stats_line "$name")"
      if [[ -n "$line" ]]; then
        stats+="$line"$'\n'
      fi
    done
  else
    ensure_stats_stream none
  fi

  local host_mem_bytes summary tot_cpu tot_mem tot_memp tot_net tot_blk tot_pids tot_cpu_host
  host_mem_bytes="$(awk '/^MemTotal:/ { printf "%.0f", $2 * 1024; exit }' /proc/meminfo 2>/dev/null || echo 0)"
  tot_cpu="0.00%" tot_mem="- / -" tot_memp="0.00%" tot_net="- / -" tot_blk="- / -" tot_pids="0" tot_cpu_host="0.00"
  if [[ -n "$stats" ]]; then
    summary="$(printf '%s\n' "$stats" | summarize_container_stats "$host_mem_bytes")"
    IFS='|' read -r tot_cpu tot_mem tot_memp tot_net tot_blk tot_pids tot_cpu_host <<< "$summary"
  fi
  tot_cpu_host="${tot_cpu_host:-0.00}"
  tot_memp="${tot_memp:-0.00%}"
  tot_pids="${tot_pids:-0}"

  print_capacity "$tot_cpu_host" "${tot_memp%"%"}" "$tot_pids"

  echo "CONTAINERS"
  printf '  %-10s %-12s %-11s %7s  %-22s %6s  %-14s %-14s %5s\n' \
    ALIAS NAME STATUS CPU MEM MEM% NET BLOCK PIDS
  local i cpu mem memp net blk pids line
  for i in "${!aliases[@]}"; do
    cpu="-" mem="-" memp="-" net="-" blk="-" pids="-"
    if [[ -n "$stats" ]]; then
      line="$(printf '%s\n' "$stats" | awk -F'|' -v n="${names[$i]}" '$1==n {print; exit}')"
      if [[ -n "$line" ]]; then
        IFS='|' read -r _ cpu mem memp net blk pids <<< "$line"
      fi
    fi
    printf '  %-10s %-12s %-11s %7s  %-22s %6s  %-14s %-14s %5s\n' \
      "${aliases[$i]}" "${names[$i]}" "${statuses[$i]}" "$cpu" "$mem" "$memp" "$net" "$blk" "$pids"
  done
  printf '  %-10s %-12s %-11s %7s  %-22s %6s  %-14s %-14s %5s\n' \
    TOTAL - - "$tot_cpu" "$tot_mem" "$tot_memp" "$tot_net" "$tot_blk" "$tot_pids"
  if [[ ${#live[@]} -gt 0 && -z "$stats" ]] && { [[ -z "$stats_pid" ]] || ! kill -0 "$stats_pid" 2>/dev/null; }; then
    echo "  (docker stats skipped — daemon busy or restarting)"
  fi
  echo
}

sample() {
  local stamp
  stamp="$(date -Is)"
  echo "===== $stamp pid=$$ ====="
  echo
  sample_containers
  sample_system "$stamp"
}

{
  echo "rlog started $(date -Is) interval=${interval}s dir=$out_dir targets=${targets:-none} history_max_bytes=$max_bytes keep_plain=$keep_plain archive_max_bytes=$archive_max"
} >> "$history"
fsync_file "$history"
rotate_history_if_needed
host_cpu_pct

while true; do
  start="$(now_s)"
  if ! sample > "$tmp"; then
    printf '%s\n' "===== $(date -Is) pid=$$ =====" "sample failed" > "$tmp"
  fi
  printf '\n' >> "$tmp" || true
  fsync_file "$tmp"
  cat "$tmp" >> "$history" || true
  fsync_file "$history"
  rotate_history_if_needed
  mv -f "$tmp" "$latest" 2>/dev/null || true
  sleep_remaining "$start"
done
