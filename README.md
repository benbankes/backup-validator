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
- Local port 80 available on `127.0.0.1`.
- Permission to update WSL's `/etc/hosts`; passwordless sudo is simplest.
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

Successful sites remain running together on port 80:

```text
http://flextalk.test
http://pursuegod.test
http://pursuegodkids.test
http://buscadedios.test
```

Port 80 is the default. If it is already occupied, choose one shared alternate
port for every restored domain:

```bash
WP_LOCAL_PORT=8080 ./wp-local-restore.sh
```

The resulting URLs include that port, such as `http://flextalk.test:8080`.

The wrapper restores databases sequentially to limit resource pressure. Each
site has its own WordPress runtime, MySQL container, private network, and
database volume. A shared nginx proxy routes `.test` hostnames to each site.

The restore updates WSL's `/etc/hosts`. A browser running on Windows does not
necessarily use that file. If a Windows browser cannot resolve a restored name,
add equivalent entries to the elevated Windows hosts file at
`C:\Windows\System32\drivers\etc\hosts`:

```text
127.0.0.1 flextalk.test
127.0.0.1 pursuegod.test
127.0.0.1 pursuegodkids.test
127.0.0.1 buscadedios.test
```

Docker Desktop normally forwards the WSL-published loopback port to Windows.

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
internet access; only the short-lived WP-CLI service has egress for checksums.

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
- **Port 80 already occupied:** stop the unmanaged listener before restoring.
- **Sudo failure:** the WSL hosts-file update requires privilege. Configure
  passwordless sudo or make Ansible become credentials available.
- **Site does not resolve in a Windows browser:** add the `.test` entries to the
  Windows hosts file as described above.
- **Restore validation fails:** inspect the per-site report and container log.

## Existing backup infrastructure

Production backup and AWS-machine playbooks remain separate from local recovery.
Consult the playbooks under `aws/` only when working on that infrastructure.
