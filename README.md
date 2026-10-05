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

## AWS setup order

[This README](#aws-operations) owns shared settings and everyday operations.
[IAM.md](aws/IAM.md) creates the local user's permissions and the EC2 upload role.
[NETWORKING-SSH.md](aws/NETWORKING-SSH.md) creates networking and establishes SSH
access. Infrastructure setup runs in administrator CloudShell; everyday commands
use the single local `backup-validator` AWS profile.

1. In WSL, install Ansible, `boto3`, `botocore`, `jq`, and the `amazon.aws` and
   `ansible.posix` collections. Install AWS CLI v2 with
   `ansible-playbook install-aws-cli.yml` (requires passwordless sudo).
2. Create the shared settings below. Fill in the account, region and globally
   unique bucket name. Keep the account ID quoted.
3. Follow networking guide sections 1–2. Record its subnet and security-group
   IDs in the local settings.
4. Upload the updated settings to CloudShell as `~/aws.yml`. Run the bucket setup
   and AMI selection below; record the AMI ID in the local settings.
5. Upload the finalized settings and repository `hosts` to CloudShell. Follow
   [IAM setup](aws/IAM.md), including configuring the local profile.
6. Create, configure and prepare the machine using [AWS operations](#aws-operations).
   Complete networking guide section 3 for website SSH access, then run a backup,
   download it and restore it locally.

### Shared AWS settings

Run once in WSL; edit the existing file for subsequent changes. This file uses
JSON syntax, which Ansible also accepts as YAML and CloudShell can read with `jq`.
Keep it outside Git. It contains configuration, not AWS credentials.

```bash
(
set -euo pipefail
umask 077
mkdir -p "$HOME/.config/backup-validator"
SETTINGS="$HOME/.config/backup-validator/aws.yml"
[[ ! -e "$SETTINGS" ]] || { echo "Edit the existing $SETTINGS"; exit 1; }
cat > "$SETTINGS" <<JSON
{
  "aws_account_id": "REPLACE_WITH_12_DIGIT_ACCOUNT_ID",
  "aws_region": "us-east-1",
  "backup_bucket": "REPLACE_WITH_BUCKET_NAME",
  "iam_user_name": "backup-operator",
  "iam_policy_name": "backup-validator-operations",
  "upload_role": "backup-validator-upload",
  "ami_id": "REPLACE_WITH_AMI_ID",
  "instance_type": "c6i.large",
  "root_volume_size": 100,
  "subnet_id": "REPLACE_WITH_SUBNET_ID",
  "security_group": "REPLACE_WITH_SECURITY_GROUP_ID",
  "key_name": "backup-validator-operator",
  "tag_name": "backup_creator_tag",
  "ansible_ssh_private_key_file": "$HOME/.ssh/backup-validator/operator"
}
JSON
)
```

The supported machine platform is Canonical Ubuntu 26.04 minimal x86_64, using
its `ubuntu` login and `/home/ubuntu/backup-validator` checkout. The AMI is pinned;
IAM and provisioning read the same ID. Instance type and root disk size are
settings; the disk uses gp3. Use a unique machine Name tag in the selected region.
Discovery rejects multiple matches, and destruction uses the same region and tag.

`hosts` is the authoritative site list (one hostname per line). Private website
credentials and paths belong in `host_vars/<site>.yml`. After changing sites or
AWS settings, reapply IAM with fresh uploaded files and rerun preparation to
refresh the remote inventory and runtime settings. Changes to launch settings
do not reconfigure an existing machine automatically.

### Backup bucket and AMI

Run in administrator CloudShell after uploading `aws.yml`. For an existing bucket,
this block verifies ownership and region and leaves its settings intact. Review
its encryption, public access, versioning and lifecycle separately before use.
For a new bucket it enables SSE-S3 encryption, versioning, owner-enforced ownership
and public-access blocking. It aborts incomplete multipart uploads after seven
days; archive retention and old-version expiration remain an explicit operator
choice. Customer-managed KMS encryption requires additional IAM permissions.

```bash
(
set -euo pipefail
export AWS_PAGER=''
SETTINGS="$HOME/aws.yml"
ACCOUNT=$(jq -er '.aws_account_id' "$SETTINGS")
REGION=$(jq -er '.aws_region' "$SETTINGS")
BUCKET=$(jq -er '.backup_bucket' "$SETTINGS")
[[ "$ACCOUNT" =~ ^[0-9]{12}$ && "$BUCKET" != REPLACE* && -n "$BUCKET" ]]
[[ $(aws sts get-caller-identity --query Account --output text) == "$ACCOUNT" ]]
OWNED=$(aws s3api list-buckets --output json | jq -r --arg b "$BUCKET" '[.Buckets[] | select(.Name == $b)] | length')
if [[ "$OWNED" == 0 ]]; then
  if [[ "$REGION" == us-east-1 ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" --region "$REGION" \
    --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
  aws s3api put-bucket-ownership-controls --bucket "$BUCKET" --region "$REGION" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
  aws s3api put-bucket-encryption --bucket "$BUCKET" --region "$REGION" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-bucket-versioning --bucket "$BUCKET" --region "$REGION" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --region "$REGION" \
    --lifecycle-configuration '{"Rules":[{"ID":"AbortIncompleteUploads","Status":"Enabled","Filter":{"Prefix":""},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}'
fi
LOCATION=$(aws s3api get-bucket-location --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT" \
  --region "$REGION" --output json | jq -r '.LocationConstraint // "us-east-1" | if . == "EU" then "eu-west-1" else . end')
[[ "$LOCATION" == "$REGION" ]] || { echo 'Bucket region differs from settings.' >&2; exit 1; }
printf 'Bucket verified: %s\n' "$BUCKET"
aws ec2 describe-images --region "$REGION" --owners 099720109477 \
  --filters 'Name=name,Values=ubuntu-minimal/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-minimal-*' \
    'Name=architecture,Values=x86_64' 'Name=state,Values=available' \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text
)
```

Record the returned `ami-...` as `ami_id`; `None` means no matching image was
found. Re-upload the edited settings before IAM setup. If bucket creation stops
partway through, finish its remaining configuration before continuing; reruns
preserve existing buckets. Bucket and network creation are administrator tasks,
not permissions granted to the everyday user.

AWS references: [bucket creation](https://docs.aws.amazon.com/cli/latest/reference/s3api/create-bucket.html)
and [lifecycle configuration](https://docs.aws.amazon.com/cli/latest/reference/s3api/put-bucket-lifecycle-configuration.html).

## AWS operations

Run local commands from the repository root in WSL:

```bash
export AWS_PROFILE=backup-validator
SETTINGS="$HOME/.config/backup-validator/aws.yml"
ansible-playbook aws/create-backup-machine.yml -e @"$SETTINGS"
ansible-playbook aws/configure-backup-machine.yml -e @"$SETTINGS"
ansible-playbook aws/prepare-backup-scripts.yml -e @"$SETTINGS"
```

Each AWS playbook checks the active account against the settings before its work.
Preparation clones the GitHub repository's default branch: publish the desired
playbook version there before preparing a machine. It then copies the local
inventory, private host variables and only the account/region/bucket settings.

Find the machine's public IP with the same settings:

```bash
aws ec2 describe-instances --region "$(jq -r '.aws_region' "$SETTINGS")" \
  --filters "Name=tag:Name,Values=$(jq -r '.tag_name' "$SETTINGS")" 'Name=instance-state-name,Values=running' \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text
```

After establishing [website SSH access](aws/NETWORKING-SSH.md#3-website-access-authorize-the-backup-machine),
run on the backup machine as `ubuntu` (its EC2 role supplies AWS credentials):

```bash
cd /home/ubuntu/backup-validator
ansible-playbook backup-all-sites.yml -e @/home/ubuntu/.config/backup-validator/aws.yml
```

Back in WSL, download and [restore locally](#restore-locally). A successful upload
alone does not demonstrate recoverability. When finished with the machine:

```bash
ansible-playbook aws/destroy-backup-machine.yml -e @"$SETTINGS"
```

Destruction handles stopped machines too, refuses multiple matches, and does
nothing if no machine matches. It deletes the machine's root disk, including its
SSH key and private runtime files; S3 archives remain. Avoid concurrent lifecycle
commands. Scheduling, failure notifications and archive retention are separate
operational decisions.

## Download latest backups from S3

In WSL, with the local profile configured:

```bash
AWS_PROFILE=backup-validator ansible-playbook download-latest-backups.yml \
  -e @"$HOME/.config/backup-validator/aws.yml"
```

Download-only settings need just `aws_account_id`, `aws_region`, and
`backup_bucket`. For every site in `hosts`, the playbook lists
`s3://<backup_bucket>/<site>/` and downloads the matching
`<site>-YYYY-MM-DD.tar.gz` archive with the newest S3 `LastModified` time into
this repository's `backups/` directory. Listing includes all pages; unrelated
files and nested paths are ignored. Missing archives or AWS errors fail the run.

Each run downloads the selected archives again. Downloads are staged and checked
against the listed size before replacing the destination; existing archives
survive failed transfers. Older local backups are retained. Add `--check` to list
the selected backups without downloading them. This requires no production SSH
access or AWS writes. Local restoration itself needs no AWS credentials.

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
- Conditional clearing and regeneration of Divi's derived `wp-content/et-cache`
  data, followed by a scan for remaining production hostnames. Sites without
  that cache directory are left unchanged.
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
