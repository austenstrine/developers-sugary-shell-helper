#!/usr/bin/env bash
# Controllable docker stub for dssh unit tests.
# Scenario file (MOCK_DOCKER_SCENARIO): KEY=value lines.
# Keys:
#   gpu_attach=ok|fail
#   has_nvidia_runtime=0|1
#   has_alpine=0|1
#   has_hello=0|1
#   inspect_compose_service=<svc>   # for any container inspect
#   inspect_running=0|1
#   image_inspect=0|1
#   ps_names=name1,name2
#   compose_ps=text
#   compose_fail=0|1
#   stats_line=...
set -euo pipefail

log="${MOCK_DOCKER_LOG:-/dev/null}"
scenario="${MOCK_DOCKER_SCENARIO:-}"
printf 'docker %s\n' "$*" >>"$log"

sc() {
	local key="$1" def="${2-}"
	[[ -n "$scenario" && -f "$scenario" ]] || { printf '%s' "$def"; return 0; }
	local line
	line="$(grep -E "^${key}=" "$scenario" 2>/dev/null | tail -n1 || true)"
	if [[ -z "$line" ]]; then
		printf '%s' "$def"
		return 0
	fi
	printf '%s' "${line#*=}"
}

# --- top-level subcommands ---
cmd="${1-}"
shift || true

case "$cmd" in
	info)
		if [[ "$(sc has_nvidia_runtime 0)" == "1" ]]; then
			echo nvidia
		fi
		exit 0
		;;
	image)
		sub="${1-}"
		shift || true
		if [[ "$sub" == "inspect" ]]; then
			img="${1-}"
			if [[ "$img" == alpine:latest && "$(sc has_alpine 1)" == "1" ]]; then
				exit 0
			fi
			if [[ "$img" == hello-world:latest && "$(sc has_hello 0)" == "1" ]]; then
				exit 0
			fi
			# Generic image inspect (built images): default ok unless image_inspect=0
			if [[ "$(sc image_inspect 1)" == "1" ]]; then
				exit 0
			fi
			exit 1
		fi
		exit 0
		;;
	run)
		# Detect --gpus attach probe
		has_gpus=0
		for a in "$@"; do
			[[ "$a" == "--gpus" ]] && has_gpus=1
		done
		if [[ "$has_gpus" == "1" ]]; then
			if [[ "$(sc gpu_attach fail)" == "ok" ]]; then
				exit 0
			fi
			echo 'Error response from daemon: could not select device driver "" with capabilities: [[gpu]]' >&2
			exit 125
		fi
		# detect_shell / generic run: succeed
		exit 0
		;;
	inspect)
		# docker inspect --type container ...
		fmt=""
		type_c=0
		name=""
		while [[ $# -gt 0 ]]; do
			case "$1" in
				--type)
					shift
					[[ "${1-}" == "container" ]] && type_c=1
					;;
				-f|--format)
					shift
					fmt="${1-}"
					;;
				*)
					name="$1"
					;;
			esac
			shift || true
		done
		if [[ "$type_c" == "1" && "$(sc inspect_running 1)" != "1" ]]; then
			exit 1
		fi
		if [[ "$fmt" == *com.docker.compose.service* ]]; then
			echo "$(sc inspect_compose_service api)"
			exit 0
		fi
		# default inspect ok
		exit 0
		;;
	ps)
		# --filter label=dssh.image / -q / --format
		quiet=0
		fmt=""
		while [[ $# -gt 0 ]]; do
			case "$1" in
				-q|--quiet) quiet=1 ;;
				--format|-f) shift; fmt="${1-}" ;;
			esac
			shift || true
		done
		names="$(sc ps_names "")"
		if [[ -z "$names" ]]; then
			exit 0
		fi
		IFS=',' read -ra arr <<<"$names"
		if [[ "$quiet" == "1" ]]; then
			for n in "${arr[@]}"; do
				echo "id-$n"
			done
			exit 0
		fi
		if [[ -n "$fmt" ]]; then
			echo -e "NAMES\tSTATUS\tPORTS"
			for n in "${arr[@]}"; do
				echo -e "${n}\tUp\t"
			done
			exit 0
		fi
		for n in "${arr[@]}"; do
			echo "$n"
		done
		exit 0
		;;
	rm|kill|stop|build)
		exit 0
		;;
	logs)
		echo "mock-docker-logs"
		# -f would hang; our tests avoid -f or we exit after one line
		exit 0
		;;
	exec)
		echo "mock-docker-exec"
		exit 0
		;;
	compose)
		if [[ "$(sc compose_fail 0)" == "1" ]]; then
			echo "mock compose fail" >&2
			exit 1
		fi
		sub="${1-}"
		shift || true
		case "$sub" in
			ps)
				printf '%s\n' "$(sc compose_ps "NAME IMAGE COMMAND SERVICE CREATED STATUS PORTS")"
				exit 0
				;;
			up|build|stop|run)
				# Record and succeed
				exit 0
				;;
			*)
				exit 0
				;;
		esac
		;;
	stats)
		# Used by rlog — print one line then exit (no follow if we ignore -a/--no-stream carefully)
		# dssh rlog uses: docker stats --format ...
		line="$(sc stats_line "")"
		if [[ -n "$line" ]]; then
			echo "$line"
		fi
		exit 0
		;;
	*)
		exit 0
		;;
esac
