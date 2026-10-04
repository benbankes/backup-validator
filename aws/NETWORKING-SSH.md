# Networking and SSH setup

Run section 1 in **local WSL**, section 2 in **administrator CloudShell**, and
section 3 back in WSL. Section 4 connects the backup machine to website servers.
The CloudShell commands create networking and import a public key; they do not
launch EC2 or create the S3 bucket. Use [IAM setup](IAM.md) between sections 2 and 3.

## 1. Local WSL: prepare the operator SSH key

Keep the private key on your workstation. This block reuses an existing key and
recreates its public half if necessary; it does not overwrite a private key.
Choose a passphrase when prompted and load it with `ssh-add` before using Ansible.

```bash
(
set -euo pipefail
KEY_FILE="$HOME/.ssh/backup-validator/operator"
mkdir -p "$(dirname "$KEY_FILE")"
chmod 700 "$(dirname "$KEY_FILE")"
if [[ ! -f "$KEY_FILE" ]]; then
  ssh-keygen -t ed25519 -f "$KEY_FILE"
fi
chmod 600 "$KEY_FILE"
ssh-keygen -y -f "$KEY_FILE" > "$KEY_FILE.pub"
ssh-keygen -lf "$KEY_FILE.pub"
printf 'Upload only this public file to CloudShell: %s.pub\n' "$KEY_FILE"
)
```

Use CloudShell's **Actions → Upload file** to upload `operator.pub`. If Windows'
file picker cannot browse your WSL files, use the distro's `\\wsl.localhost\` path.
Do not upload `operator` (the private key).

## 2. CloudShell: create or reuse the network

Edit the variables, including your workstation's public IPv4 `/32` and the
**website SSH servers'** IPv4 CIDRs (from `ansible_host`, not CDN/web addresses).
Choose private CIDRs that do not overlap connected networks. The example uses
`us-east-1`; choose an available zone supporting the intended instance type.

Leave `VPC_ID` and `SUBNET_ID` empty to create/find resources using the
`BackupNetwork` tag. Set them to explicitly reuse a VPC and a subnet dedicated to
this backup machine. The gateway is reused by its VPC attachment; the route table
and security group are found by their tag inside the VPC. Duplicate matches stop
the commands. Reruns verify existing settings and stop on conflicts rather than
replace routes, firewall rules or SSH keys. A fresh subnet's association with the
new public route table is intentional; do not select a shared workload subnet.

Paste the whole block into CloudShell Bash. It stops on errors without rolling
back earlier creations. After a partial failure, inspect the printed resources
and fix the incomplete resource before rerunning; tag lookup avoids duplicating it.

```bash
(
set -euo pipefail
export AWS_PAGER=''
umask 077
EXPECTED_ACCOUNT='REPLACE_WITH_12_DIGIT_ACCOUNT_ID'
REGION='us-east-1'
AZ='us-east-1a'
NETWORK_NAME='backup-validator'
VPC_CIDR='10.80.0.0/16'
SUBNET_CIDR='10.80.1.0/24'
OPERATOR_CIDR='REPLACE_WITH_YOUR_PUBLIC_IP/32'
SITE_SSH_CIDRS=('REPLACE_WITH_WEBSITE_SSH_IP/32')
KEY_NAME='backup-validator-operator'
PUBLIC_KEY_FILE="$HOME/operator.pub"
VPC_ID=''
SUBNET_ID=''

fail() { echo "$*" >&2; exit 1; }
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
[[ "$EXPECTED_ACCOUNT" =~ ^[0-9]{12}$ && "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT" ]] || fail 'Wrong or unset account ID.'
[[ "$NETWORK_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || fail 'Use letters, digits, underscores or hyphens for NETWORK_NAME.'
[[ "$OPERATOR_CIDR" != REPLACE* && ${#SITE_SSH_CIDRS[@]} -gt 0 ]] || fail 'Set operator and website SSH CIDRs.'
for cidr in "$OPERATOR_CIDR" "${SITE_SSH_CIDRS[@]}"; do
  [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || fail "Invalid IPv4 CIDR: $cidr"
done
[[ "$OPERATOR_CIDR" == */32 ]] || fail 'Use your workstation public IPv4 /32 for inbound SSH.'
[[ -s "$PUBLIC_KEY_FILE" ]] || fail 'Upload operator.pub to CloudShell first.'
ssh-keygen -lf "$PUBLIC_KEY_FILE" > /dev/null
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
ec2() { aws ec2 "$@" --region "$REGION" --output json; }
one() { jq -r 'if length == 0 then "" elif length == 1 then .[0] else error("Multiple matches: supply explicit IDs or unique tags") end'; }

if [[ -z "$VPC_ID" ]]; then
  VPC_ID=$(ec2 describe-vpcs --filters "Name=tag:BackupNetwork,Values=$NETWORK_NAME" | jq '[.Vpcs[].VpcId]' | one)
fi
if [[ -z "$VPC_ID" ]]; then
  VPC_ID=$(ec2 create-vpc --cidr-block "$VPC_CIDR" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=BackupNetwork,Value=$NETWORK_NAME}]" | jq -r '.Vpc.VpcId')
  ec2 wait vpc-available --vpc-ids "$VPC_ID"
  ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
  ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
fi
printf 'VPC_ID=%s\n' "$VPC_ID"
for attribute in enableDnsSupport enableDnsHostnames; do
  ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute "$attribute" \
    | jq -e '[.[] | objects | .Value?] | any(. == true)' > /dev/null || fail "Enable $attribute on $VPC_ID before proceeding."
done

if [[ -z "$SUBNET_ID" ]]; then
  SUBNET_ID=$(ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
    "Name=tag:BackupNetwork,Values=$NETWORK_NAME" | jq '[.Subnets[].SubnetId]' | one)
fi
if [[ -z "$SUBNET_ID" ]]; then
  SUBNET_ID=$(ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_CIDR" --availability-zone "$AZ" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=BackupNetwork,Value=$NETWORK_NAME}]" | jq -r '.Subnet.SubnetId')
  ec2 wait subnet-available --subnet-ids "$SUBNET_ID"
fi
ec2 describe-subnets --subnet-ids "$SUBNET_ID" \
  | jq -e --arg vpc "$VPC_ID" --arg cidr "$SUBNET_CIDR" --arg az "$AZ" \
    '.Subnets | length == 1 and .[0].VpcId == $vpc and .[0].CidrBlock == $cidr and .[0].AvailabilityZone == $az' > /dev/null \
  || fail 'Subnet does not match VPC, CIDR and AZ; correct the inputs.'
printf 'SUBNET_ID=%s\n' "$SUBNET_ID"

IGW_ID=$(ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" | jq '[.InternetGateways[].InternetGatewayId]' | one)
if [[ -z "$IGW_ID" ]]; then
  IGW_ID=$(ec2 describe-internet-gateways --filters "Name=tag:BackupNetwork,Values=$NETWORK_NAME" | jq '[.InternetGateways[].InternetGatewayId]' | one)
  if [[ -z "$IGW_ID" ]]; then
    IGW_ID=$(ec2 create-internet-gateway \
      --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=BackupNetwork,Value=$NETWORK_NAME}]" | jq -r '.InternetGateway.InternetGatewayId')
  fi
  # Fails if the tagged gateway belongs to another VPC; never detach it.
  ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi
ROUTE_TABLE_ID=$(ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
  "Name=tag:BackupNetwork,Values=$NETWORK_NAME" | jq '[.RouteTables[].RouteTableId]' | one)
if [[ -z "$ROUTE_TABLE_ID" ]]; then
  ROUTE_TABLE_ID=$(ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=BackupNetwork,Value=$NETWORK_NAME}]" | jq -r '.RouteTable.RouteTableId')
fi
ec2 describe-route-tables --route-table-ids "$ROUTE_TABLE_ID" > "$WORK_DIR/routes.json"
DEFAULT_ROUTES=$(jq '[.RouteTables[0].Routes[] | select(.DestinationCidrBlock == "0.0.0.0/0")]' "$WORK_DIR/routes.json")
if [[ "$DEFAULT_ROUTES" == '[]' ]]; then
  ec2 create-route --route-table-id "$ROUTE_TABLE_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
else
  jq -e --arg gateway "$IGW_ID" 'length == 1 and .[0].GatewayId == $gateway and .[0].State == "active"' \
    <<< "$DEFAULT_ROUTES" > /dev/null || fail 'Default route conflicts with the intended internet gateway.'
fi
ASSOCIATED=$(ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$SUBNET_ID" | jq '[.RouteTables[].RouteTableId]' | one)
if [[ -z "$ASSOCIATED" ]]; then
  ec2 associate-route-table --route-table-id "$ROUTE_TABLE_ID" --subnet-id "$SUBNET_ID"
else
  [[ "$ASSOCIATED" == "$ROUTE_TABLE_ID" ]] || fail 'Subnet is explicitly associated with a different route table.'
fi

jq -n --arg cidr "$OPERATOR_CIDR" \
  '[{IpProtocol:"tcp",FromPort:22,ToPort:22,IpRanges:[{CidrIp:$cidr}]}]' > "$WORK_DIR/ingress.json"
jq -n --args '[{IpProtocol:"tcp",FromPort:80,ToPort:80,IpRanges:[{CidrIp:"0.0.0.0/0"}]},
  {IpProtocol:"tcp",FromPort:443,ToPort:443,IpRanges:[{CidrIp:"0.0.0.0/0"}]},
  {IpProtocol:"tcp",FromPort:22,ToPort:22,IpRanges:($ARGS.positional | unique | map({CidrIp:.}))}]' \
  "${SITE_SSH_CIDRS[@]}" > "$WORK_DIR/egress.json"
SECURITY_GROUP_ID=$(ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
  "Name=tag:BackupNetwork,Values=$NETWORK_NAME" | jq '[.SecurityGroups[].GroupId]' | one)
if [[ -z "$SECURITY_GROUP_ID" ]]; then
  SECURITY_GROUP_ID=$(ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$NETWORK_NAME-ssh" \
    --description 'Backup machine SSH and upload access' \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=BackupNetwork,Value=$NETWORK_NAME}]" | jq -r '.GroupId')
  printf 'SECURITY_GROUP_ID=%s\n' "$SECURITY_GROUP_ID"
  ec2 describe-security-groups --group-ids "$SECURITY_GROUP_ID" | jq '.SecurityGroups[0].IpPermissionsEgress' > "$WORK_DIR/default-egress.json"
  if [[ $(jq length "$WORK_DIR/default-egress.json") -gt 0 ]]; then
    ec2 revoke-security-group-egress --group-id "$SECURITY_GROUP_ID" --ip-permissions "file://$WORK_DIR/default-egress.json"
  fi
  ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --ip-permissions "file://$WORK_DIR/ingress.json"
  ec2 authorize-security-group-egress --group-id "$SECURITY_GROUP_ID" --ip-permissions "file://$WORK_DIR/egress.json"
fi
# Compare rule meaning, ignoring descriptions and AWS-added empty fields.
NORMALIZE='map({IpProtocol,FromPort,ToPort,IpRanges:([.IpRanges[]?.CidrIp]|sort),Ipv6Ranges:([.Ipv6Ranges[]?.CidrIpv6]|sort),PrefixListIds:([.PrefixListIds[]?.PrefixListId]|sort),UserIdGroupPairs:(.UserIdGroupPairs // [])}) | sort_by(.IpProtocol,.FromPort,.ToPort)'
ec2 describe-security-groups --group-ids "$SECURITY_GROUP_ID" > "$WORK_DIR/group.json"
for direction in ingress egress; do
  field=IpPermissions; [[ "$direction" == ingress ]] || field=IpPermissionsEgress
  jq -S ".SecurityGroups[0].$field | $NORMALIZE" "$WORK_DIR/group.json" > "$WORK_DIR/actual.json"
  jq -S "$NORMALIZE" "$WORK_DIR/$direction.json" > "$WORK_DIR/expected.json"
  cmp -s "$WORK_DIR/actual.json" "$WORK_DIR/expected.json" || fail "Existing $direction rules differ; review $SECURITY_GROUP_ID rather than overwrite its rules."
done

ec2 describe-key-pairs --filters "Name=key-name,Values=$KEY_NAME" --include-public-key > "$WORK_DIR/key.json"
if [[ $(jq '.KeyPairs | length' "$WORK_DIR/key.json") == 0 ]]; then
  ec2 import-key-pair --key-name "$KEY_NAME" --public-key-material "fileb://$PUBLIC_KEY_FILE"
else
  LOCAL_KEY=$(awk 'NF >= 2 {print $1 " " $2; exit}' "$PUBLIC_KEY_FILE")
  AWS_KEY=$(jq -r '.KeyPairs[0].PublicKey' "$WORK_DIR/key.json" | awk 'NF >= 2 {print $1 " " $2; exit}')
  [[ "$LOCAL_KEY" == "$AWS_KEY" ]] || fail 'Existing key name has different public key material; use the correct key or another name.'
fi
printf '\nCopy these into IAM.md and your Ansible settings:\n'
printf 'EXPECTED_ACCOUNT=%s\nREGION=%s\nSUBNET_ID=%s\nSECURITY_GROUP_ID=%s\nKEY_NAME=%s\n' \
  "$ACCOUNT_ID" "$REGION" "$SUBNET_ID" "$SECURITY_GROUP_ID" "$KEY_NAME"
printf 'Network references: VPC=%s IGW=%s ROUTE_TABLE=%s\n' "$VPC_ID" "$IGW_ID" "$ROUTE_TABLE_ID"
)
```

This uses a public IPv4 address (requested by the launch playbook), an internet
gateway and outbound TCP 22/80/443. No NAT gateway is needed. Keep the default
network ACL or ensure custom ACLs allow traffic and its return paths. DNS must
remain available through the VPC resolver. An existing subnet's custom ACL is not
validated by these commands. Update reviewed security-group rules when your home
IP or website SSH addresses change; reruns deliberately flag the mismatch.

Now run [IAM setup](IAM.md) using the printed values and your bucket name. Network
bootstrap requires EC2 create/attach/associate/route, DNS modification, security-group
rule, key import, tagging and Describe permissions; these stay with the CloudShell
administrator, not the everyday IAM user.

## 3. Local WSL: configure and launch

After configuring the `backup-validator` profile in IAM setup, paste the printed
values into this block. Store settings locally, outside the repository. Existing
settings are retained; edit that file directly when changing infrastructure.

```bash
(
set -euo pipefail
mkdir -p "$HOME/.config/backup-validator"
chmod 700 "$HOME/.config/backup-validator"
SETTINGS="$HOME/.config/backup-validator/aws.yml"
if [[ ! -e "$SETTINGS" ]]; then
  (umask 077; cat > "$SETTINGS" <<YAML
aws_region: us-east-1
subnet_id: subnet-REPLACE
security_group: sg-REPLACE
key_name: backup-validator-operator
iam_profile: arn:aws:iam::ACCOUNT_ID:instance-profile/backup-validator-upload
tag_name: backup_creator_tag
backup_bucket: BUCKET_NAME
ansible_ssh_private_key_file: $HOME/.ssh/backup-validator/operator
YAML
  )
fi
printf 'Review and replace placeholders in %s before launching.\n' "$SETTINGS"
)
```

Run the following from the repository root after filling in that file. If your
private key has a passphrase, load it into an SSH agent first.

```bash
(
set -euo pipefail
SETTINGS="$HOME/.config/backup-validator/aws.yml"
if grep -Eq 'REPLACE|ACCOUNT_ID|BUCKET_NAME' "$SETTINGS"; then
  echo "Fill in $SETTINGS first." >&2; exit 1
fi
export AWS_PROFILE=backup-validator
aws sts get-caller-identity
ansible-playbook aws/create-backup-machine.yml -e "@$SETTINGS"
ansible-playbook aws/configure-backup-machine.yml -e "@$SETTINGS"
ansible-playbook aws/prepare-backup-scripts.yml -e "@$SETTINGS"
)
```

Creation waits for SSH as `ubuntu`. A timeout calls for checking the instance's
public IP, route-table association, operator `/32`, key pair and private key.
Verify the machine's SSH host-key fingerprint through a trusted channel such as
EC2 console output before accepting it. The creation playbook can terminate extra
instances matching its tag; use a separate reviewed tag/policy for isolated tests.

## 4. Website access: authorize the backup machine

Configuration creates a second key, `/home/ubuntu/.ssh/id_rsa`, **on EC2**. This key
is for EC2-to-website access; your workstation key is for workstation-to-EC2 access.
If the hosting provider restricts source IPs, allow the backup machine's public
IPv4 address for SSH. A new machine or stop/start can change that address; update
allowlists or separately configure an Elastic IP if a stable address is required.

SSH from WSL to the machine, substituting its public IP:

```bash
ssh -i "$HOME/.ssh/backup-validator/operator" ubuntu@BACKUP_MACHINE_PUBLIC_IP
```

On the backup machine, for each website, install its public key using the existing
website login and test key-only access. Replace `SITE_USER` and `SITE_SSH_HOST`
with the private host-variable values, and verify the website's host-key fingerprint
before accepting it. If password login is unavailable, use the hosting provider's
SSH-key administration interface to install the output of `cat ~/.ssh/id_rsa.pub`.

```bash
ssh-copy-id -i ~/.ssh/id_rsa.pub SITE_USER@SITE_SSH_HOST
ssh -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/id_rsa SITE_USER@SITE_SSH_HOST true
```

Never copy either private key to the website servers. The backup playbook also
installs the EC2 public key using the existing credentials in `host_vars`, but
running it performs a real backup, not just a connectivity check.

On EC2, confirm the upload role and perform a backup when ready:

```bash
aws sts get-caller-identity
cd /home/ubuntu/backup-validator
ansible-playbook backup-all-sites.yml -e backup_bucket=BUCKET_NAME
```

Back in the local repository, download and use the README's restore procedure:

```bash
AWS_PROFILE=backup-validator ansible-playbook download-latest-backups.yml \
  -e "@$HOME/.config/backup-validator/aws.yml"
```

The upload command currently disables SSH host-key checking; this guide does not
change that command. Keep verified host keys for subsequent hardening. Scheduling
and failure notifications require separate configuration.

## References

- [Internet gateway requirements](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html)
- [Read existing EC2 public keys](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-key-pairs.html)
- [Route-table queries](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-route-tables.html)
