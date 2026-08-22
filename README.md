# WordPress backup and local recovery validation

This repository creates WordPress backups with Ansible and can restore those
backups into isolated local Docker environments for recovery testing. Local
restore commands do not access S3 and do not create, change, or destroy cloud
infrastructure.

## Local restore prerequisites

- WSL with Bash, Ansible, `tar`, and `ss`.
- Docker Desktop with WSL integration enabled for this distribution, or another
  Docker daemon accessible to the current WSL user.
- Docker Compose (`docker compose`).
- Local port 8080 available on `127.0.0.1`.
- Permission to update WSL's `/etc/hosts`; passwordless sudo is simplest.
- A `127.0.0.1 <site>.test` entry in the Windows hosts file for each site being
  restored. The restore checks these mappings before starting Docker work and
  prints copy/paste-ready guidance when any are missing.
- Populated `host_vars/<site>.yml` environment-version declarations.

Confirm Docker access before restoring:

```bash
docker info
docker compose version
```

## Backup archive format

Place archives in `backups/` at the repository root. Filenames must use the
same format produced for S3:

```text
<inventory-host>-YYYY-MM-DD.tar.gz
```

For example, `backups/flextalk.org-2026-08-20.tar.gz` must contain:

```text
database.sql
files/
  wp-config.php
  wp-settings.php
  wp-includes/
  wp-content/
  ...
```

When several dated archives exist for one site, the date encoded in the
filename determines which is newest. Older archives are reported and skipped.
Unrecognized `.tar.gz` filenames cause the restore to stop rather than being
silently ignored.

## Restore locally

Restore the newest available archive for every represented inventory site:

```bash
./wp-local-restore.sh
```

Restore one site:

```bash
./wp-local-restore.sh flextalk.org
```

Restore several sites concurrently with a bounded worker count:

```bash
./wp-local-restore.sh --parallel 2
./wp-local-restore.sh --parallel 4
```

Sequential restoration remains the default. Parallel mode overlaps archive
processing, MySQL imports, URL conversion, and validation while locking shared
proxy and WSL hosts-file changes. Higher values can increase CPU, memory, and
disk contention, so `--parallel 2` is the recommended starting point.

Successful sites remain running together on port 8080:

```text
http://flextalk.test:8080
http://pursuegod.test:8080
http://pursuegodkids.test:8080
http://buscadedios.test:8080
```

Port 8080 is the default. To choose another shared port for every restored
domain:

```bash
WP_LOCAL_PORT=9090 ./wp-local-restore.sh
```

The resulting URLs include that port, such as `http://flextalk.test:9090`.

Each site has its own WordPress runtime, MySQL container, private network, and
database volume. A shared nginx proxy routes `.test` hostnames to each site.

The restore updates WSL's `/etc/hosts`. A browser running on Windows does not
use that file. Before doing any expensive work, the restore therefore verifies
equivalent entries in the Windows hosts file at
`C:\Windows\System32\drivers\etc\hosts`:

```text
127.0.0.1 flextalk.test
127.0.0.1 pursuegod.test
127.0.0.1 pursuegodkids.test
127.0.0.1 buscadedios.test
```

Docker Desktop normally forwards the WSL-published loopback port to Windows.
If Windows is installed somewhere other than the standard C: location, set the
WSL path explicitly, for example:

```bash
WINDOWS_HOSTS_FILE=/mnt/d/Windows/System32/drivers/etc/hosts ./wp-local-restore.sh
```

## Validation and artifacts

For each site, the restore checks:

- PHP, MySQL, WordPress, and Apache/nginx version families.
- WordPress installation state, database integrity, plugins, and themes.
- WordPress core checksums.
- Serialized-data-safe conversion of production URLs to the `.test` URL.
- Homepage and `/wp-admin/` responses through the shared proxy.
- A sampled upload when media exists.
- Container output for PHP fatal errors.

Generated state is stored under `.restore/`:

```text
.restore/<site>/validation-report.yml
.restore/<site>/containers.log
.restore/<site>/compose.yml
.restore/proxy/
```

A failed validation leaves its workspace and logs available for diagnosis. The
source archive is never modified. Application containers have no outbound
internet access.

To reduce container startup overhead, each site reuses one temporary WP-CLI
container for configuration, URL conversion, and validation commands. That
container has temporary internet egress so it can verify WordPress checksums and
is removed after validation or by the cleanup command. If a restore is
interrupted, it may remain until the site is restored again or cleaned up.

Media validation stops after finding and requesting one supported upload. This
confirms that recovered media is present and reachable, but it does not validate
every upload or guarantee that the same sample is selected on every run.

## Cleanup

```bash
./wp-local-cleanup.sh flextalk.org  # Remove one restored site
./wp-local-cleanup.sh               # Remove every local restore
```

Cleanup removes generated containers, networks, database volumes, proxy routes,
WSL hosts entries, and `.restore/` workspaces. It never removes `backups/`.

Both commands provide built-in help:

```bash
./wp-local-restore.sh --help
./wp-local-cleanup.sh --help
```

## Troubleshooting

- **Cannot connect to Docker:** enable Docker Desktop WSL integration and verify
  `docker info` succeeds without sudo. If `/usr/bin/docker` points into
  `/mnt/wsl/docker-desktop/cli-tools/` but that directory is empty, disable and
  re-enable integration for this distro in Docker Desktop, then apply/restart.
- **Port 8080 already occupied:** stop the unmanaged listener or select another
  shared port with `WP_LOCAL_PORT` before restoring.
- **Sudo failure:** the WSL hosts-file update requires privilege. Configure
  passwordless sudo or make Ansible become credentials available.
- **Missing Windows hosts entries:** open the path printed by the restore as
  Administrator, paste the generated mappings, save it, and rerun.
- **Restore validation fails:** inspect the per-site report and container log.

## Existing backup infrastructure

Production backup and AWS-machine playbooks remain separate from local recovery.
Consult the playbooks under `aws/` only when working on that infrastructure.
