#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
backup_dir="${repo_dir}/backups"
inventory_file="${repo_dir}/hosts"
playbook="${repo_dir}/wordpress-from-backup.yml"
default_http_port=8080
restore_http_port="${WP_LOCAL_PORT:-$default_http_port}"
windows_hosts_file="${WINDOWS_HOSTS_FILE:-/mnt/c/Windows/System32/drivers/etc/hosts}"
parallelism=1
requested_site=""

usage() {
  cat <<'EOF'
Usage: ./wp-local-restore.sh [--parallel N] [SITE]

Restore the newest dated backup for SITE, or every site represented in
backups/ when SITE is omitted.

Examples:
  ./wp-local-restore.sh
  ./wp-local-restore.sh --parallel 2
  ./wp-local-restore.sh --parallel 4
  ./wp-local-restore.sh flextalk.org

Expected archive name: <inventory-host>-YYYY-MM-DD.tar.gz

The shared local proxy listens on 127.0.0.1:8080 by default. Set
WP_LOCAL_PORT to use another port, for example:
  WP_LOCAL_PORT=9090 ./wp-local-restore.sh

Set WINDOWS_HOSTS_FILE only when Windows is installed somewhere other than the
standard /mnt/c/Windows location.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --parallel)
      if (( $# < 2 )); then
        printf '%s\n' '--parallel requires a positive integer.' >&2
        exit 2
      fi
      parallelism="$2"
      shift 2
      ;;
    --parallel=*)
      parallelism="${1#*=}"
      shift
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$requested_site" ]]; then
        printf 'Only one site may be specified.\n' >&2
        usage >&2
        exit 2
      fi
      requested_site="$1"
      shift
      ;;
  esac
done

if [[ ! "$parallelism" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' '--parallel must be a positive integer.' >&2
  exit 2
fi

if [[ ! -d "$backup_dir" ]]; then
  printf 'Backup directory does not exist: %s\n' "$backup_dir" >&2
  exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  printf 'ansible-playbook is required but was not found.\n' >&2
  exit 1
fi

if ! command -v flock >/dev/null 2>&1; then
  printf 'flock is required for safe shared-state coordination but was not found.\n' >&2
  exit 1
fi

if [[ ! "$restore_http_port" =~ ^[0-9]+$ ]] ||
   (( restore_http_port < 1 || restore_http_port > 65535 )); then
  printf 'WP_LOCAL_PORT must be an integer from 1 through 65535.\n' >&2
  exit 1
fi

mapfile -t inventory_sites < <(
  sed -E 's/[[:space:]]+#.*$//; /^[[:space:]]*($|#|\[)/d; s/[[:space:]].*$//' "$inventory_file"
)

if (( ${#inventory_sites[@]} == 0 )); then
  printf 'No sites were found in %s.\n' "$inventory_file" >&2
  exit 1
fi

declare -A configured=()
declare -A latest_date=()
declare -A latest_archive=()
declare -A older_archives=()
for site in "${inventory_sites[@]}"; do
  configured["$site"]=1
done

if [[ -n "$requested_site" && -z "${configured[$requested_site]:-}" ]]; then
  printf 'Unknown site: %s\nConfigured sites: %s\n' \
    "$requested_site" "${inventory_sites[*]}" >&2
  exit 1
fi

shopt -s nullglob
archives=("${backup_dir}"/*.tar.gz)
shopt -u nullglob
if (( ${#archives[@]} == 0 )); then
  printf 'No .tar.gz archives were found in %s.\n' "$backup_dir" >&2
  exit 1
fi

invalid_archives=()
for archive in "${archives[@]}"; do
  filename="${archive##*/}"
  matched_site=""
  encoded_date=""

  for site in "${inventory_sites[@]}"; do
    prefix="${site}-"
    if [[ "$filename" == "$prefix"*.tar.gz ]]; then
      candidate="${filename#"$prefix"}"
      candidate="${candidate%.tar.gz}"
      if [[ "$candidate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] &&
         [[ "$(date -d "$candidate" +%F 2>/dev/null || true)" == "$candidate" ]]; then
        matched_site="$site"
        encoded_date="$candidate"
      fi
      break
    fi
  done

  if [[ -z "$matched_site" ]]; then
    invalid_archives+=("$filename")
    continue
  fi

  if [[ -z "${latest_date[$matched_site]:-}" || "$encoded_date" > "${latest_date[$matched_site]}" ]]; then
    if [[ -n "${latest_archive[$matched_site]:-}" ]]; then
      older_archives["$matched_site"]+="${latest_archive[$matched_site]}"$'\n'
    fi
    latest_date["$matched_site"]="$encoded_date"
    latest_archive["$matched_site"]="$archive"
  else
    older_archives["$matched_site"]+="$archive"$'\n'
  fi
done

if (( ${#invalid_archives[@]} > 0 )); then
  printf 'Unrecognized backup archive name(s):\n' >&2
  printf '  %s\n' "${invalid_archives[@]}" >&2
  printf 'Expected <inventory-host>-YYYY-MM-DD.tar.gz.\n' >&2
  exit 1
fi

selected_sites=()
if [[ -n "$requested_site" ]]; then
  if [[ -z "${latest_archive[$requested_site]:-}" ]]; then
    printf 'No dated backup was found for %s in %s.\n' "$requested_site" "$backup_dir" >&2
    exit 1
  fi
  selected_sites+=("$requested_site")
else
  for site in "${inventory_sites[@]}"; do
    if [[ -n "${latest_archive[$site]:-}" ]]; then
      selected_sites+=("$site")
    else
      printf 'Warning: no backup found for configured site %s; skipping.\n' "$site" >&2
    fi
  done
fi

if (( ${#selected_sites[@]} == 0 )); then
  printf 'No restorable archives were selected.\n' >&2
  exit 1
fi

if [[ ! -r "$windows_hosts_file" ]]; then
  printf '%s\n' \
    "Windows hosts file is not readable from WSL: ${windows_hosts_file}" \
    'Mount the Windows drive or set WINDOWS_HOSTS_FILE to its WSL path, then retry.' >&2
  exit 1
fi

missing_windows_hosts=()
for site in "${selected_sites[@]}"; do
  local_site="${site%.*}.test"
  if ! awk -v required_host="$local_site" '
    {
      sub(/\r$/, "")
      sub(/[[:space:]]*#.*/, "")
      if ($1 == "127.0.0.1") {
        for (field = 2; field <= NF; field++) {
          if ($field == required_host) {
            found = 1
          }
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$windows_hosts_file"; then
    missing_windows_hosts+=("$local_site")
  fi
done

if (( ${#missing_windows_hosts[@]} > 0 )); then
  printf '%s\n' \
    'Missing required Windows hosts entries.' \
    '' \
    'Open this file as Administrator:' \
    'C:\Windows\System32\drivers\etc\hosts' \
    '' \
    'Add:' >&2
  for local_site in "${missing_windows_hosts[@]}"; do
    printf '127.0.0.1 %s\n' "$local_site" >&2
  done
  printf '\nThen rerun:\n' >&2
  if [[ -n "$requested_site" ]]; then
    if (( restore_http_port == default_http_port )); then
      printf './wp-local-restore.sh %s\n' "$requested_site" >&2
    else
      printf 'WP_LOCAL_PORT=%s ./wp-local-restore.sh %s\n' "$restore_http_port" "$requested_site" >&2
    fi
  elif (( restore_http_port == default_http_port )); then
    printf './wp-local-restore.sh\n' >&2
  else
    printf 'WP_LOCAL_PORT=%s ./wp-local-restore.sh\n' "$restore_http_port" >&2
  fi
  exit 1
fi

if ! command -v docker >/dev/null 2>&1 || [[ ! -x "$(command -v docker 2>/dev/null)" ]]; then
  printf '%s\n' \
    'Docker CLI is unavailable in this WSL distro.' \
    'Enable this distro in Docker Desktop > Settings > Resources > WSL integration,' \
    'apply the change, and verify that `docker info` succeeds before retrying.' >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  printf 'Docker Compose is unavailable; verify `docker compose version` before retrying.\n' >&2
  exit 1
fi

export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/backup-validator-ansible-local}"
export ANSIBLE_REMOTE_TEMP="${ANSIBLE_REMOTE_TEMP:-/tmp/backup-validator-ansible-remote}"

failures=()
declare -A restore_pid_site=()
running=0

run_restore() {
  local site="$1"
  local archive="$2"
  local command=(
    ansible-playbook "$playbook"
    --extra-vars "restore_site=${site}"
    --extra-vars "backup_archive=${archive}"
    --extra-vars "restore_http_port=${restore_http_port}"
  )

  if (( parallelism == 1 )); then
    "${command[@]}"
  else
    "${command[@]}" 2>&1 | sed -u "s/^/[${site}] /"
  fi
}

wait_for_restore() {
  local finished_pid=""
  local finished_site=""

  if wait -n -p finished_pid; then
    :
  else
    finished_site="${restore_pid_site[$finished_pid]}"
    failures+=("$finished_site")
  fi
  unset 'restore_pid_site[$finished_pid]'
  running=$((running - 1))
}

if (( parallelism == 1 )); then
  printf 'Restoring %d site(s) sequentially; successful sites remain running.\n' "${#selected_sites[@]}"
else
  printf 'Restoring %d site(s), up to %d in parallel; successful sites remain running.\n' \
    "${#selected_sites[@]}" "$parallelism"
fi

for site in "${selected_sites[@]}"; do
  archive="${latest_archive[$site]}"
  printf '\n==> %s\n    archive: %s\n' "$site" "${archive##*/}"
  if [[ -n "${older_archives[$site]:-}" ]]; then
    printf '    skipped older archive(s):\n'
    while IFS= read -r older; do
      [[ -n "$older" ]] && printf '      %s\n' "${older##*/}"
    done <<< "${older_archives[$site]}"
  fi

  run_restore "$site" "$archive" &
  restore_pid_site[$!]="$site"
  running=$((running + 1))

  if (( running >= parallelism )); then
    wait_for_restore
  fi
done

while (( running > 0 )); do
  wait_for_restore
done

printf '\nLocal restore summary:\n'
for site in "${selected_sites[@]}"; do
  if [[ " ${failures[*]:-} " == *" ${site} "* ]]; then
    printf '  FAIL  %s (see .restore/%s/)\n' "$site" "$site"
  else
    local_site="${site%.*}.test"
    if (( restore_http_port == 80 )); then
      printf '  PASS  http://%s\n' "$local_site"
    else
      printf '  PASS  http://%s:%s\n' "$local_site" "$restore_http_port"
    fi
  fi
done

if (( ${#failures[@]} > 0 )); then
  exit 1
fi

printf '\nCleanup: ./wp-local-cleanup.sh%s\n' "${requested_site:+ ${requested_site}}"
