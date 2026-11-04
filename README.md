# developers-sugary-shell-helper (`dssh`)

Generic project-root Docker / Compose / npm orchestrator with a small resource logger (`rlog`).

Consumer-specific names (container names, compose services, health probes, deploy scripts) live in the consumer’s **`.dsshrc`**, not in this tool.

## Install

```bash
git clone https://github.com/austenstrine/developers-sugary-shell-helper.git
cd developers-sugary-shell-helper
./install.sh          # symlinks bin/dssh → ~/.local/bin/dssh
# ensure ~/.local/bin is on PATH
```

Or point at the binary directly:

```bash
export DSSH_BIN=/path/to/developers-sugary-shell-helper/bin/dssh
```

`rlog.sh` ships next to `bin/dssh` and is started by `dssh rlog`.

## Project root

`dssh` finds the consumer project by:

1. `DSSH_PROJECT_ROOT`, or
2. directory of `DSSH_CONFIG_FILE`, or
3. walking up from `$PWD` for `.dsshrc` / `.dsshrc.local`

Host/key overrides go in gitignored `.dsshrc.local`.

## RC schema (high level)

| Key | Purpose |
|-----|---------|
| `dssh_targets` | Comma-separated target aliases (`backend,frontend,…`) |
| `<target>=<dir>` | App directory (usually has a Dockerfile) |
| `<target>_name` | Container name (live + local start) |
| `<target>_service` | Compose service name on live |
| `<target>_aliases` | Alternate names (`api` → `backend`) |
| `<target>_image` / `_context` / `_dockerfile` / `_user` / `_workdir` | Build/run overrides |
| `<target>_<action>` | Command inside the container |
| `<target>_<action>_local` | Host command before/instead of container action |
| `dssh_mode` | `auto` \| `live` \| `local` (or `DSSH_MODE`) |
| `dssh_live_compose_file` / `dssh_live_compose_prod_file` | Compose overlay paths |
| `dssh_live_container_prefix` | Fallback container name = prefix + service |
| `dssh_live_detect_targets` | Targets whose containers trigger `auto` → live |
| `dssh_live_app_services` / `dssh_live_infra_services` | Compose service lists |
| `dssh_live_health_containers` | Explicit health container list (optional) |
| `dssh_live_health_url` / `_url_http` | HTTP probe URLs |
| `dssh_live_health_exec_container` / `_exec_url` | Fallback in-container probe |
| `dssh_live_migrate_service` / `dssh_live_migrate_cmd` | Live migrate |
| `dssh_migrate_target` | Local `dssh migrate` → `<target> migrate` |
| `dssh_publish_local` | Required for `dssh publish` |
| `dssh_env_backup_relpath` | Relative to `<alias>_repo` after `rnano` |
| `dssh_rlog_*` | Resource logger interval/dir/targets/retention |
| `dssh_stop_local` / `dssh_status_local` / … | Global host actions |

See [`examples/dsshrc.example`](examples/dsshrc.example) for a commented template.

## Example consumer config

Minimal live-capable map (names are yours — this is illustrative):

```bash
dssh_targets=api,web,proxy
dssh_mode=auto
dssh_live_detect_targets=api,web,proxy
dssh_live_app_services=api,web,proxy
dssh_live_infra_services=db
dssh_live_container_prefix=myapp-
dssh_live_health_url=https://127.0.0.1/healthz
dssh_publish_local=./scripts/deploy.sh

api=./apps/api
api_service=api
api_name=myapp-api
api_start="npm run dev"

web=./apps/web
web_service=web
web_name=myapp-web
web_start="npm run dev"

proxy=./ops/proxy
proxy_service=proxy
proxy_name=myapp-proxy
proxy_aliases=nginx
proxy_start="nginx -g 'daemon off;'"
```

First consumer in the wild: [austenstrine/austenstrine_portfolio](https://github.com/austenstrine/austenstrine_portfolio) (keeps portfolio `.dsshrc`, thin `./dssh` wrapper).

## Commands (overview)

```text
dssh <global-action>          # publish | status | health | logs | rlog | migrate | stop | rnano | …
dssh <target> start|restart|stop|build|…
dssh <target>                 # shell into running container (live) / interactive (local)
dssh gpu-setup                # install NVIDIA Container Toolkit (may fail loudly)
dssh gpu-probe                # soft-detect Docker GPU; prints --gpus all|cpu-only (exit 0)
```

`dssh_gpus=auto` (default) enables `--gpus all` only after a real Docker attach probe succeeds. Missing toolkit, broken vendor/device discovery after a kernel upgrade, or empty GPU devices log a warning and continue cpu-only — start/restart/build never abort for GPU discovery. Set `dssh_gpus=off` to skip probing.

Smoke: `tests/smoke-gpu-soft-fallback.sh`.

## License

MIT (same as typical austenstrine tooling unless noted otherwise).
