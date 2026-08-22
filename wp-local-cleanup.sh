#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
restore_root="${repo_dir}/.restore"
inventory_file="${repo_dir}/hosts"
playbook="${repo_dir}/wp-local-cleanup.yml"

usage() {
  cat <<'EOF'
Usage: ./wp-local-cleanup.sh [SITE]

Remove SITE's generated local restore, or all managed local restores when SITE
is omitted. Source archives in backups/ are never removed.

Examples:
  ./wp-local-cleanup.sh
  ./wp-local-cleanup.sh flextalk.org
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if (( $# > 1 )); then
  usage >&2
  exit 2
fi

requested_site="${1:-}"

if ! command -v ansible-playbook >/dev/null 2>&1; then
  printf 'ansible-playbook is required but was not found.\n' >&2
  exit 1
fi

mapfile -t inventory_sites < <(
  sed -E 's/[[:space:]]+#.*$//; /^[[:space:]]*($|#|\[)/d; s/[[:space:]].*$//' "$inventory_file"
)

declare -A configured=()
for site in "${inventory_sites[@]}"; do
  configured["$site"]=1
done

if [[ -n "$requested_site" && -z "${configured[$requested_site]:-}" ]]; then
  printf 'Unknown site: %s\n' "$requested_site" >&2
  exit 1
fi

selected_sites=()
if [[ -n "$requested_site" ]]; then
  selected_sites+=("$requested_site")
else
  for site in "${inventory_sites[@]}"; do
    if [[ -d "${restore_root}/${site}" ]]; then
      selected_sites+=("$site")
    fi
  done
fi

if (( ${#selected_sites[@]} == 0 )); then
  printf 'No matching local WordPress restores exist. Nothing to remove.\n'
  exit 0
fi

printf 'Removing local restore resources for:\n'
printf '  %s\n' "${selected_sites[@]}"
printf 'Source archives under backups/ will not be touched.\n'

export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/backup-validator-ansible-local}"
export ANSIBLE_REMOTE_TEMP="${ANSIBLE_REMOTE_TEMP:-/tmp/backup-validator-ansible-remote}"

failures=()
for site in "${selected_sites[@]}"; do
  if ! ansible-playbook "$playbook" --extra-vars "restore_site=${site}"; then
    failures+=("$site")
  fi
done

printf '\nCleanup summary:\n'
for site in "${selected_sites[@]}"; do
  if [[ " ${failures[*]:-} " == *" ${site} "* ]]; then
    printf '  FAIL  %s\n' "$site"
  else
    printf '  REMOVED  %s\n' "$site"
  fi
done

(( ${#failures[@]} == 0 ))
