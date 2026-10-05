#!/usr/bin/env bash
# Resolve Ansible SSH endpoints without exposing other inventory variables.
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_dir"

for tool in ansible-inventory jq getent; do
  command -v "$tool" >/dev/null || { echo "Required command not found: $tool" >&2; exit 1; }
done

# Keep only site/SSH endpoint fields; never print the complete private inventory.
endpoints=$(ansible-inventory -i hosts --list | jq -er '
  ._meta.hostvars | to_entries | map(select(.key != "localhost")) |
  if length == 0 then error("No website hosts in inventory") else . end |
  sort_by(.key)[] |
  if (.value.ansible_host | type) != "string" then
    error("Set ansible_host for " + .key)
  elif (.value.ansible_host | test("^[A-Za-z0-9][A-Za-z0-9.-]*$")) | not then
    error("Expected an SSH hostname or IPv4 address for " + .key)
  elif ((.value.ansible_port // 22) | tostring) != "22" then
    error("SSH port is not 22 for " + .key + "; the current firewall/upload workflow requires port 22")
  else [.key, .value.ansible_host] | @tsv end
')

declare -A cidrs=()
while IFS=$'\t' read -r site ssh_host; do
  if ! resolved=$(getent ahostsv4 "$ssh_host"); then
    echo "Cannot resolve IPv4 for $site (ansible_host=$ssh_host). No CIDRs emitted." >&2
    exit 1
  fi
  addresses=$(awk '{print $1}' <<< "$resolved" | sort -u)
  [[ -n "$addresses" ]] || { echo "No IPv4 addresses for $site ($ssh_host)." >&2; exit 1; }
  while IFS= read -r address; do
    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
      echo "Unexpected resolver output for $ssh_host." >&2; exit 1;
    }
    cidrs["$address/32"]=1
    printf '%s: %s -> %s/32\n' "$site" "$ssh_host" "$address" >&2
  done <<< "$addresses"
done <<< "$endpoints"

mapfile -t sorted_cidrs < <(printf '%s\n' "${!cidrs[@]}" | sort)
printf 'SITE_SSH_CIDRS=('
printf "'%s' " "${sorted_cidrs[@]}"
printf ')\n'
