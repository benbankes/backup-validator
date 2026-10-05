# Set up and test backups, one stage at a time

Follow this guide from top to bottom. Stop at each checkpoint before starting the
next stage. Commands marked **CloudShell** run as an administrator in the target
AWS account; commands marked **WSL** run locally from this repository. **EC2**
commands run as `ubuntu` on the backup machine.

| Stage | Create or configure now | Uses earlier results |
| --- | --- | --- |
| 1. Provision | Network, operator SSH access, IAM user, EC2 role/profile, machine | None |
| 2. Configure | Machine packages and its website SSH key | Machine |
| 3. Back up and upload | Bucket, S3 permissions, website SSH access, backup scripts | Configured machine and role |
| 4. Download | No additional AWS setup | Bucket and local IAM user |
| 5. Restore and verify locally | Docker and local hostnames | Downloaded archives |
| 6. Terminate | Scoped termination permission | Machine tag and local IAM user |

There is one local AWS profile: `backup-validator`. AWS credentials remain in
that profile as an expiring browser-login session. The machine uses its EC2 role,
with no user keys copied to it.
CloudShell records discovered IDs in `~/backup-validator/aws.yml` as resources
become available. The file uses JSON syntax, also accepted by Ansible as YAML.
There is no bucket field until stage 3 and no placeholder IDs to fill in locally.
Retain the CloudShell file for subsequent stages and reruns.

## 1. Provision

### 1.1 CloudShell: choose the region and discover account and image

Sign into the intended AWS account as an administrator and open CloudShell in the
region where the machine should run. Confirm the account in the AWS console.
The block discovers the account ID, region, latest supported Ubuntu image and an
availability zone offering the selected instance type. Review the printed values
before proceeding. Instance availability still depends on capacity and quotas.

You may change the instance type, disk size and dedicated resource names in this
block before its first run. These are deployment choices, not IDs to look up.
Reruns retain the saved image and settings and reject another account or region.
This workflow supports standard commercial AWS regions and Canonical Ubuntu
26.04 minimal x86_64.

```bash
(
set -euo pipefail
export AWS_PAGER=''
umask 077
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
[[ "$REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ && "$REGION" != cn-* ]] || {
  echo 'Open CloudShell in a standard commercial region.' >&2; exit 1;
}
IDENTITY=$(aws sts get-caller-identity --output json)
ACCOUNT=$(jq -er '.Account' <<< "$IDENTITY")
[[ $(jq -r '.Arn' <<< "$IDENTITY") == arn:aws:* ]]
SETTINGS="$HOME/backup-validator/aws.yml"
mkdir -p "$(dirname "$SETTINGS")"
if [[ -e "$SETTINGS" ]]; then
  jq -e --arg account "$ACCOUNT" --arg region "$REGION" \
    '.aws_account_id == $account and .aws_region == $region' "$SETTINGS" > /dev/null
  cat "$SETTINGS"
  exit 0
fi
INSTANCE_TYPE='c6i.large'
ROOT_VOLUME_SIZE=100
AMI=$(aws ec2 describe-images --region "$REGION" --owners 099720109477 \
  --filters 'Name=name,Values=ubuntu-minimal/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-minimal-*' \
    'Name=architecture,Values=x86_64' 'Name=state,Values=available' \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
AZ=$(aws ec2 describe-instance-type-offerings --region "$REGION" --location-type availability-zone \
  --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
  --query 'sort(InstanceTypeOfferings[].Location)[0]' --output text)
[[ "$AMI" == ami-* && "$AZ" == "$REGION"* ]] || {
  echo 'No supported AMI or instance-type offering; choose another region/type.' >&2; exit 1;
}
jq -n --arg account "$ACCOUNT" --arg region "$REGION" --arg ami "$AMI" \
  --arg az "$AZ" --arg type "$INSTANCE_TYPE" --argjson size "$ROOT_VOLUME_SIZE" '{
  aws_account_id:$account, aws_region:$region, ami_id:$ami, availability_zone:$az,
  instance_type:$type, root_volume_size:$size,
  iam_user_name:"backup-operator", iam_policy_name:"backup-validator-operations",
  upload_role:"backup-validator-upload", key_name:"backup-validator-operator",
  tag_name:"backup_creator_tag"
}' > "$SETTINGS"
cat "$SETTINGS"
)
```

### 1.2 WSL: prepare the operator public key

Local prerequisites: Bash, OpenSSH, Ansible with the `amazon.aws` and
`ansible.posix` collections, and `jq`. Install AWS CLI v2 (2.32.0 or later) if
needed with `ansible-playbook install-aws-cli.yml` (uses passwordless sudo).
Install the SDK used by the local AWS playbooks:

```bash
ansible-playbook install-python3-requirements.yml
```

This installs/upgrades Boto3 1.41.0+ with AWS CRT in `.venv/aws`, leaving Ubuntu's
system Python packages intact. The local plays under `aws/` explicitly use this
interpreter; no virtual-environment activation is required. Run the installer in
each new checkout. No AWS profile or local settings file is required yet.

Create or reuse the operator key. Choose a passphrase when prompted; load the key
into your SSH agent with `ssh-add ~/.ssh/backup-validator/operator` before Ansible.
The private key stays in WSL.

```bash
(
set -euo pipefail
KEY_FILE="$HOME/.ssh/backup-validator/operator"
mkdir -p "$(dirname "$KEY_FILE")"
chmod 700 "$(dirname "$KEY_FILE")"
if [[ ! -f "$KEY_FILE" ]]; then ssh-keygen -t ed25519 -f "$KEY_FILE"; fi
chmod 600 "$KEY_FILE"
ssh-keygen -y -f "$KEY_FILE" > "$KEY_FILE.pub"
ssh-keygen -lf "$KEY_FILE.pub"
printf 'Upload this public file to CloudShell: %s.pub\n' "$KEY_FILE"
)
```

Use CloudShell **Actions → Upload file** to upload `operator.pub` into your
CloudShell home directory. A Windows file picker can reach WSL through
`\\wsl.localhost\<distro>\home\<user>`. Do not upload the private key.

### 1.3 CloudShell: create networking and import the public key

Set `OPERATOR_CIDR` to your workstation's public IPv4 address followed by `/32`.
This is the workstation address, not CloudShell's. Review the private CIDRs for
conflicts with connected networks. Other defaults can be kept for a dedicated
backup network. Leave `VPC_ID`/`SUBNET_ID` empty for tag-based creation/reuse.

The block saves the resulting IDs itself. It allows inbound SSH from your
workstation and outbound HTTP/HTTPS for package installation. Website SSH egress
is added in stage 3. Existing conflicting resources cause a failure rather than
being overwritten. Commands are not transactional: after a partial failure,
inspect the printed resources and finish incomplete configuration before retrying.

```bash
(
set -euo pipefail
export AWS_PAGER=''
umask 077
SETTINGS_FILE="$HOME/backup-validator/aws.yml"
EXPECTED_ACCOUNT=$(jq -er '.aws_account_id' "$SETTINGS_FILE")
REGION=$(jq -er '.aws_region' "$SETTINGS_FILE")
AZ=$(jq -er '.availability_zone' "$SETTINGS_FILE")
NETWORK_NAME='backup-validator'
VPC_CIDR='10.80.0.0/16'
SUBNET_CIDR='10.80.1.0/24'
OPERATOR_CIDR='209.147.110.171/32'
# Initially empty; later backup setup records website destinations here.
mapfile -t SITE_SSH_CIDRS < <(jq -r '.site_ssh_cidrs // [] | .[]' "$SETTINGS_FILE")
KEY_NAME=$(jq -er '.key_name' "$SETTINGS_FILE")
PUBLIC_KEY_FILE="$HOME/operator.pub"
VPC_ID=''
SUBNET_ID=''

fail() { echo "$*" >&2; exit 1; }
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
[[ "$EXPECTED_ACCOUNT" =~ ^[0-9]{12}$ && "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT" ]] || fail 'Wrong or unset account ID.'
[[ "$AZ" == "$REGION"* ]] || fail 'Choose an availability zone in the configured region.'
[[ "$NETWORK_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || fail 'Use letters, digits, underscores or hyphens for NETWORK_NAME.'
[[ "$OPERATOR_CIDR" != REPLACE* ]] || fail 'Set your workstation public IPv4 CIDR.'
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
  {IpProtocol:"tcp",FromPort:443,ToPort:443,IpRanges:[{CidrIp:"0.0.0.0/0"}]}]
  + (if ($ARGS.positional | length) > 0 then [{IpProtocol:"tcp",FromPort:22,ToPort:22,IpRanges:($ARGS.positional | unique | map({CidrIp:.}))}] else [] end)' \
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
jq --arg subnet "$SUBNET_ID" --arg sg "$SECURITY_GROUP_ID" --arg vpc "$VPC_ID" \
  '. + {subnet_id:$subnet, security_group:$sg, vpc_id:$vpc}' \
  "$SETTINGS_FILE" > "$WORK_DIR/settings.json"
mv "$WORK_DIR/settings.json" "$SETTINGS_FILE"
printf 'Network and public key ready. Settings saved to %s\n' "$SETTINGS_FILE"
)
```

### 1.4 CloudShell: create provisioning access

Use dedicated IAM names. Existing unrelated user/role policies, group memberships
and keys are preserved and may confer additional permissions. This block creates
an EC2 role/profile with its trust policy now, because launching the machine
requires the profile. It grants that role no S3 access yet.

The operator gets AWS-managed `ReadOnlyAccess`, `SignInLocalDevelopmentAccess`,
and narrowly scoped launch/tag/pass-role permissions. If the user has no console
login, the block prompts twice for a password without echoing it. Choose and save
a password that meets the account's password policy. It is sent through a private
temporary JSON file, then removed; it is never printed or put in command arguments.
An existing console password is preserved. No permanent access key is created.
No bucket, site inventory or website credentials are needed here.
Policy updates are idempotent; a changed policy at the five-version limit removes
its oldest nondefault version. IAM propagation may briefly delay first use.

```bash
(
set -euo pipefail
export AWS_PAGER=''
umask 077

SETTINGS_FILE="$HOME/backup-validator/aws.yml"
EXPECTED_ACCOUNT=$(jq -er '.aws_account_id' "$SETTINGS_FILE")
REGION=$(jq -er '.aws_region' "$SETTINGS_FILE")
USER_NAME=$(jq -er '.iam_user_name' "$SETTINGS_FILE")
SUBNET_ID=$(jq -er '.subnet_id' "$SETTINGS_FILE")
SECURITY_GROUP_ID=$(jq -er '.security_group' "$SETTINGS_FILE")
KEY_NAME=$(jq -er '.key_name' "$SETTINGS_FILE")
INSTANCE_TYPE=$(jq -er '.instance_type' "$SETTINGS_FILE")
MACHINE_TAG=$(jq -er '.tag_name' "$SETTINGS_FILE")
UPLOAD_ROLE=$(jq -er '.upload_role' "$SETTINGS_FILE")
POLICY_NAME=$(jq -er '.iam_policy_name' "$SETTINGS_FILE")
AMI_ID=$(jq -er '.ami_id' "$SETTINGS_FILE")
ROOT_VOLUME_SIZE=$(jq -er '.root_volume_size | select(type == "number" and floor == . and . >= 8 and . <= 16384)' "$SETTINGS_FILE")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
[[ "$EXPECTED_ACCOUNT" =~ ^[0-9]{12}$ && "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT" ]] || {
  echo 'Set aws_account_id to the intended CloudShell account in the shared settings.' >&2; exit 1;
}
[[ "$SUBNET_ID" == subnet-* && "$SECURITY_GROUP_ID" == sg-* ]] || {
  echo 'Create the network before IAM setup.' >&2; exit 1;
}
# These names are inserted into JSON below; reject shell/JSON metacharacters.
for value in "$USER_NAME" "$KEY_NAME" "$UPLOAD_ROLE" "$POLICY_NAME" "$MACHINE_TAG" "$INSTANCE_TYPE" "$REGION"; do
  [[ "$value" =~ ^[A-Za-z0-9_.+=,@-]+$ ]] || { echo "Invalid name: $value" >&2; exit 1; }
done
[[ "$AMI_ID" =~ ^ami-[a-f0-9]+$ ]] || { echo 'Pin ami_id in the shared settings first.' >&2; exit 1; }
aws ec2 describe-images --region "$REGION" --owners 099720109477 --image-ids "$AMI_ID" --output json \
  | jq -e '.Images | length == 1 and .[0].State == "available" and .[0].Architecture == "x86_64" and (.[0].Name | startswith("ubuntu-minimal/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-minimal-"))' > /dev/null

POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"
ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$UPLOAD_ROLE"
PROFILE_ARN="arn:aws:iam::$ACCOUNT_ID:instance-profile/$UPLOAD_ROLE"
EC2_ARN="arn:aws:ec2:$REGION:$ACCOUNT_ID"
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Only NoSuchEntity means absent; access/network failures stop the setup.
exists() {
  if "$@" > "$WORK_DIR/lookup.json" 2> "$WORK_DIR/error.txt"; then return 0; fi
  if grep -q '(NoSuchEntity)' "$WORK_DIR/error.txt"; then return 1; fi
  cat "$WORK_DIR/error.txt" >&2
  exit 1
}

cat > "$WORK_DIR/trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]
}
JSON
cat > "$WORK_DIR/operations.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LaunchApprovedResources", "Effect": "Allow", "Action": "ec2:RunInstances",
      "Resource": ["arn:aws:ec2:$REGION::image/$AMI_ID", "$EC2_ARN:subnet/$SUBNET_ID",
                   "$EC2_ARN:security-group/$SECURITY_GROUP_ID", "$EC2_ARN:key-pair/$KEY_NAME"]
    },
    {
      "Sid": "LaunchBackupInstance", "Effect": "Allow", "Action": "ec2:RunInstances",
      "Resource": "$EC2_ARN:instance/*",
      "Condition": {"StringEquals": {"aws:RequestTag/Name": "$MACHINE_TAG", "ec2:InstanceType": "$INSTANCE_TYPE"},
                    "ArnEquals": {"ec2:InstanceProfile": "$PROFILE_ARN"}}
    },
    {
      "Sid": "LaunchRootVolume", "Effect": "Allow", "Action": "ec2:RunInstances",
      "Resource": "$EC2_ARN:volume/*",
      "Condition": {"StringEquals": {"ec2:VolumeType": "gp3"}, "NumericLessThanEquals": {"ec2:VolumeSize": "$ROOT_VOLUME_SIZE"}}
    },
    {
      "Sid": "LaunchNetworkInterface", "Effect": "Allow", "Action": "ec2:RunInstances",
      "Resource": "$EC2_ARN:network-interface/*",
      "Condition": {"ArnEquals": {"ec2:Subnet": "$EC2_ARN:subnet/$SUBNET_ID"}}
    },
    {
      "Sid": "TagDuringLaunch", "Effect": "Allow", "Action": "ec2:CreateTags",
      "Resource": ["$EC2_ARN:instance/*", "$EC2_ARN:volume/*"],
      "Condition": {"StringEquals": {"ec2:CreateAction": "RunInstances", "aws:RequestTag/Name": "$MACHINE_TAG"},
                    "ForAllValues:StringEquals": {"aws:TagKeys": ["Name"]}}
    },
    {
      "Sid": "PassUploadRole", "Effect": "Allow", "Action": "iam:PassRole", "Resource": "$ROLE_ARN",
      "Condition": {"StringEquals": {"iam:PassedToService": "ec2.amazonaws.com"}}
    }
  ]
}
JSON
# Validate before changing IAM. Stop for any finding so it can be reviewed.
for policy in operations; do
  aws accessanalyzer validate-policy --region "$REGION" --policy-type IDENTITY_POLICY \
    --policy-document "file://$WORK_DIR/$policy.json" > "$WORK_DIR/findings.json"
  jq -e '.findings | length == 0' "$WORK_DIR/findings.json" > /dev/null || {
    cat "$WORK_DIR/findings.json"; exit 1;
  }
done

if ! exists aws iam get-user --user-name "$USER_NAME"; then
  aws iam create-user --user-name "$USER_NAME" > /dev/null
fi
if exists aws iam get-role --role-name "$UPLOAD_ROLE"; then
  aws iam update-assume-role-policy --role-name "$UPLOAD_ROLE" --policy-document "file://$WORK_DIR/trust.json"
else
  aws iam create-role --role-name "$UPLOAD_ROLE" --assume-role-policy-document "file://$WORK_DIR/trust.json" > /dev/null
fi
if ! exists aws iam get-instance-profile --instance-profile-name "$UPLOAD_ROLE"; then
  aws iam create-instance-profile --instance-profile-name "$UPLOAD_ROLE" > /dev/null
fi
PROFILE_ROLES=$(aws iam get-instance-profile --instance-profile-name "$UPLOAD_ROLE" \
  --query 'InstanceProfile.Roles[].RoleName' --output json)
if [[ "$PROFILE_ROLES" == '[]' ]]; then
  aws iam add-role-to-instance-profile --instance-profile-name "$UPLOAD_ROLE" --role-name "$UPLOAD_ROLE"
else
  jq -e --arg role "$UPLOAD_ROLE" 'length == 1 and .[0] == $role' <<< "$PROFILE_ROLES" > /dev/null || {
    echo 'Instance profile contains another role; inspect it before proceeding.' >&2; exit 1;
  }
fi

# Use a managed policy: this document can exceed IAM user inline-policy limits.
if exists aws iam get-policy --policy-arn "$POLICY_ARN"; then
  VERSION=$(jq -r '.Policy.DefaultVersionId' "$WORK_DIR/lookup.json")
  aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$VERSION" \
    --query PolicyVersion.Document --output json | jq -S . > "$WORK_DIR/previous.json"
  jq -S . "$WORK_DIR/operations.json" > "$WORK_DIR/desired.json"
  if ! cmp -s "$WORK_DIR/previous.json" "$WORK_DIR/desired.json"; then
    aws iam list-policy-versions --policy-arn "$POLICY_ARN" > "$WORK_DIR/versions.json"
    if [[ $(jq '.Versions | length' "$WORK_DIR/versions.json") -ge 5 ]]; then
      OLDEST=$(jq -r '.Versions | map(select(.IsDefaultVersion == false)) | sort_by(.CreateDate) | .[0].VersionId' "$WORK_DIR/versions.json")
      aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST"
    fi
    aws iam create-policy-version --policy-arn "$POLICY_ARN" \
      --policy-document "file://$WORK_DIR/operations.json" --set-as-default > /dev/null
  fi
else
  aws iam create-policy --policy-name "$POLICY_NAME" \
    --policy-document "file://$WORK_DIR/operations.json" > /dev/null
fi
aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess
aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN"
# Prompt only when enabling console access for the first time.
# Disable shell tracing before handling the password, even if the caller enabled it.
set +x
if ! exists aws iam get-login-profile --user-name "$USER_NAME"; then
  read -r -s -p "Choose a console password for $USER_NAME: " CONSOLE_PASSWORD < /dev/tty
  printf '\n' > /dev/tty
  read -r -s -p 'Repeat the console password: ' CONFIRM_PASSWORD < /dev/tty
  printf '\n' > /dev/tty
  [[ -n "$CONSOLE_PASSWORD" && "$CONSOLE_PASSWORD" == "$CONFIRM_PASSWORD" ]] || {
    echo 'Passwords are empty or do not match; rerun this step.' >&2; exit 1;
  }
  printf '%s' "$CONSOLE_PASSWORD" | jq -Rs --arg user "$USER_NAME" \
    '{UserName:$user, Password:., PasswordResetRequired:false}' > "$WORK_DIR/login.json"
  unset CONSOLE_PASSWORD CONFIRM_PASSWORD
  aws iam create-login-profile --cli-input-json "file://$WORK_DIR/login.json" > /dev/null
  rm -f -- "$WORK_DIR/login.json"
fi
printf 'Console sign-in: https://%s.signin.aws.amazon.com/console\nUser: %s\n' "$ACCOUNT_ID" "$USER_NAME"
printf 'User: %s\nInstance profile: %s\nAllowed AMI: %s\n' "$USER_NAME" "$PROFILE_ARN" "$AMI_ID"
)
```

### 1.5 CloudShell, then WSL: browser login and download real settings

If returning from the older access-key instructions, rerun **1.4** first. It adds
console access (only if missing) and the browser-login permission; earlier network
steps do not need repeating. Run the SDK installer from 1.2 if not already updated.

Use the account-specific console URL printed by 1.4 and sign in as the dedicated
operator user. When the CLI opens the browser, choose this user's session rather
than an administrator/root session. Enable MFA for this console user through your
account's normal administrator-managed enrollment process.

In the **administrator CloudShell**, use **Actions → Download file** to download
`/home/cloudshell-user/backup-validator/aws.yml` (use `echo "$HOME"` if your home
path differs). The file contains configuration only, not credentials.

In **WSL**, run this block and supply the path to that downloaded file. It sets
the profile's region, opens browser-based login and checks that the credentials
belong to the expected account/user. It then writes the local settings, adding
only the local SSH-key path. No account IDs or resource IDs need retyping.
Existing local settings are kept as `aws.yml.previous` before replacement.

```bash
(
set -euo pipefail
umask 077
read -r -p 'Path to the downloaded aws.yml in WSL: ' DOWNLOADED
REGION=$(jq -er '.aws_region' "$DOWNLOADED")
aws configure set region "$REGION" --profile backup-validator
aws login --profile backup-validator --remote
IDENTITY=$(aws sts get-caller-identity --profile backup-validator --output json)
ACCOUNT=$(jq -er '.Account' <<< "$IDENTITY")
USER_NAME=$(jq -er '.iam_user_name' "$DOWNLOADED")
jq -e --arg account "$ACCOUNT" '.aws_account_id == $account' "$DOWNLOADED" > /dev/null
[[ $(jq -r '.Arn' <<< "$IDENTITY") == "arn:aws:iam::$ACCOUNT:user/$USER_NAME" ]]
# Check the exact SDK used by Ansible, and reject credentials shadowing the login.
SDK_IDENTITY=$(.venv/aws/bin/python - <<'PYTHON'
import json
import boto3
session = boto3.Session(profile_name="backup-validator")
credentials = session.get_credentials()
if credentials is None or credentials.method != "login":
    raise SystemExit("Expected browser-login credentials. Remove stale static credentials for this profile and unset AWS credential environment variables, then retry.")
identity = session.client("sts").get_caller_identity()
print(json.dumps({"Account": identity["Account"], "Arn": identity["Arn"]}))
PYTHON
)
jq -e --arg account "$ACCOUNT" --arg arn "arn:aws:iam::$ACCOUNT:user/$USER_NAME" \
  '.Account == $account and .Arn == $arn' <<< "$SDK_IDENTITY" > /dev/null
SETTINGS="$HOME/.config/backup-validator/aws.yml"
mkdir -p "$(dirname "$SETTINGS")"
if [[ -f "$SETTINGS" ]]; then cp -p "$SETTINGS" "$SETTINGS.previous"; fi
WORK_FILE=$(mktemp)
trap 'rm -f -- "$WORK_FILE"' EXIT
jq --arg account "$ACCOUNT" --arg key "$HOME/.ssh/backup-validator/operator" \
  '.aws_account_id = $account | .ansible_ssh_private_key_file = $key' "$DOWNLOADED" > "$WORK_FILE"
install -m 600 "$WORK_FILE" "$SETTINGS"
printf 'Local settings ready: %s\n' "$SETTINGS"
)
```

`--remote` prints a URL to open in the Windows browser and asks for the returned
code in WSL. The CLI and SDK refresh temporary credentials during the session.
When the session expires (at most 12 hours), rerun
`aws login --profile backup-validator --remote`; the settings file remains valid.
Do not run `aws configure` to enter access keys. If this profile previously held
static keys, remove those profile entries and unset exported credential variables
so they do not override browser login. Existing AWS keys are not deleted by setup.

### 1.6 WSL: provision the machine

```bash
AWS_PROFILE=backup-validator ansible-playbook aws/create-backup-machine.yml \
  -e @"$HOME/.config/backup-validator/aws.yml"
```

**Checkpoint:** the playbook creates the uniquely tagged machine and waits for
SSH. Stop here to verify provisioning. No S3 bucket or upload permissions exist
from this setup yet. The next stage needs no additional AWS permissions.

## 2. Configure

In **WSL**, install the machine's packages and generate its separate website SSH key:

```bash
AWS_PROFILE=backup-validator ansible-playbook aws/configure-backup-machine.yml \
  -e @"$HOME/.config/backup-validator/aws.yml"
```

**Checkpoint:** configuration succeeds and `/home/ubuntu/.ssh/id_rsa.pub` exists
on EC2. The operator key connects WSL to EC2; this new key connects EC2 to websites.
Do not run `prepare-backup-scripts.yml` yet: it copies the backup destination,
which is created next.

## 3. Back up and upload

First check the repository's `hosts` inventory in WSL and populate
`host_vars/<site>.yml` from `host_vars/example.com.yml.example` for each site.
Use the existing production SSH/database credentials, paths and environment
versions. These private files stay out of Git and are copied to EC2 in 3.4.

### 3.1 CloudShell: create the destination bucket

Return to administrator CloudShell in the same account. The default bucket name
uses the account and region. If it is unavailable, change the `BUCKET` assignment
to another globally unique name. The chosen name is saved only after successful
creation/ownership/region checks. Nothing needs to be entered into local settings.

A new bucket receives SSE-S3 encryption, public-access blocking, owner-enforced
ownership, versioning and a seven-day incomplete-multipart-upload cleanup rule.
Archive expiration is not enabled. An existing owned bucket is left unchanged;
review its encryption, public access, ownership, versioning and lifecycle before
using it. Customer-managed KMS encryption needs additional permissions. If creation
partially fails, finish configuration before rerunning; existing buckets are preserved.

```bash
(
set -euo pipefail
export AWS_PAGER=''
umask 077
SETTINGS="$HOME/backup-validator/aws.yml"
ACCOUNT=$(jq -er '.aws_account_id' "$SETTINGS")
REGION=$(jq -er '.aws_region' "$SETTINGS")
# Reuse the saved bucket on reruns, otherwise choose an account/region-based name.
BUCKET=$(jq -r --arg name "backup-validator-$ACCOUNT-$REGION" '.backup_bucket // $name' "$SETTINGS")
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
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
jq --arg bucket "$BUCKET" '. + {backup_bucket:$bucket}' "$SETTINGS" > "$WORK_DIR/settings.json"
mv "$WORK_DIR/settings.json" "$SETTINGS"
)
```

### 3.2 CloudShell: grant archive upload access and publish the bucket name

Upload the repository's current `hosts` file to CloudShell as `~/hosts`. It is the
single site list: one hostname per line, with optional blank/comment lines.
Do not upload private `host_vars` files. This block grants both the EC2 role and
the operator user upload/abort access only to the listed sites' archive paths.
It tags the role with the established bucket name so the read-only local user
can discover it without another settings-file download.

```bash
(
set -euo pipefail
export AWS_PAGER=''
umask 077
SETTINGS="$HOME/backup-validator/aws.yml"
ACCOUNT=$(jq -er '.aws_account_id' "$SETTINGS")
REGION=$(jq -er '.aws_region' "$SETTINGS")
BUCKET=$(jq -er '.backup_bucket' "$SETTINGS")
USER_NAME=$(jq -er '.iam_user_name' "$SETTINGS")
ROLE=$(jq -er '.upload_role' "$SETTINGS")
[[ $(aws sts get-caller-identity --query Account --output text) == "$ACCOUNT" ]]
aws s3api head-bucket --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT" --region "$REGION"
[[ -r "$HOME/hosts" ]]
mapfile -t SITES < <(awk 'NF && $1 !~ /^#/ {print $1}' "$HOME/hosts" | sort -u)
[[ ${#SITES[@]} -gt 0 ]]
for site in "${SITES[@]}"; do [[ "$site" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; done
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
jq -n --arg bucket "$BUCKET" --args '{Version:"2012-10-17",Statement:[{
  Sid:"UploadArchives",Effect:"Allow",Action:["s3:PutObject","s3:AbortMultipartUpload"],
  Resource:($ARGS.positional | map("arn:aws:s3:::\($bucket)/\(.)/\(.)-*.tar.gz"))
}]}' "${SITES[@]}" > "$WORK_DIR/upload.json"
# Leave room within the smaller, aggregate IAM user inline-policy limit.
[[ $(jq -c . "$WORK_DIR/upload.json" | wc -c) -lt 1500 ]] || {
  echo 'Site list exceeds the inline-policy budget; use a managed upload policy.' >&2; exit 1;
}
aws accessanalyzer validate-policy --region "$REGION" --policy-type IDENTITY_POLICY \
  --policy-document "file://$WORK_DIR/upload.json" > "$WORK_DIR/findings.json"
jq -e '.findings | length == 0' "$WORK_DIR/findings.json" > /dev/null || {
  cat "$WORK_DIR/findings.json"; exit 1;
}
aws iam put-role-policy --role-name "$ROLE" --policy-name BackupUpload --policy-document "file://$WORK_DIR/upload.json"
aws iam put-user-policy --user-name "$USER_NAME" --policy-name BackupUpload --policy-document "file://$WORK_DIR/upload.json"
aws iam tag-role --role-name "$ROLE" --tags "Key=BackupBucket,Value=$BUCKET"
)
```

### 3.3 CloudShell: allow outbound website SSH

Set the website SSH servers' IPv4 CIDRs below using their `ansible_host` addresses,
not CDN/web-server addresses. Prefer `/32` entries for individual servers. No new
inbound rule is needed. Existing matching SSH egress is reused; conflicting rules
stop the block for review. Recorded CIDRs let network setup recognize these rules
on later reruns.

```bash
(
set -euo pipefail
export AWS_PAGER=''
umask 077
SITE_SSH_CIDRS=('REPLACE_WITH_WEBSITE_SSH_IP/32')
for cidr in "${SITE_SSH_CIDRS[@]}"; do
  [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]
done
[[ ${#SITE_SSH_CIDRS[@]} -gt 0 ]]
SETTINGS="$HOME/backup-validator/aws.yml"
ACCOUNT=$(jq -er '.aws_account_id' "$SETTINGS")
REGION=$(jq -er '.aws_region' "$SETTINGS")
SG=$(jq -er '.security_group' "$SETTINGS")
[[ $(aws sts get-caller-identity --query Account --output text) == "$ACCOUNT" ]]
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
jq -n --args '[{IpProtocol:"tcp",FromPort:22,ToPort:22,IpRanges:($ARGS.positional | unique | map({CidrIp:.}))}]' \
  "${SITE_SSH_CIDRS[@]}" > "$WORK_DIR/ssh.json"
aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG" --output json \
  | jq '[.SecurityGroups[0].IpPermissionsEgress[] | select(.IpProtocol == "tcp" and .FromPort == 22 and .ToPort == 22)]' > "$WORK_DIR/existing.json"
if [[ $(jq length "$WORK_DIR/existing.json") == 0 ]]; then
  aws ec2 authorize-security-group-egress --region "$REGION" --group-id "$SG" \
    --ip-permissions "file://$WORK_DIR/ssh.json"
else
  jq -e --slurpfile desired "$WORK_DIR/ssh.json" '
    length == 1 and ([.[0].IpRanges[]?.CidrIp] | sort) == ([$desired[0][0].IpRanges[].CidrIp] | sort)
    and ([.[0].Ipv6Ranges[]?, .[0].UserIdGroupPairs[]?, .[0].PrefixListIds[]?] | length == 0)
  ' "$WORK_DIR/existing.json" > /dev/null || {
    echo 'Existing SSH egress differs; review it before proceeding.' >&2; exit 1;
  }
fi
CIDRS=$(jq -cn --args '$ARGS.positional | unique' "${SITE_SSH_CIDRS[@]}")
jq --argjson cidrs "$CIDRS" '.site_ssh_cidrs = $cidrs' "$SETTINGS" > "$WORK_DIR/settings.json"
mv "$WORK_DIR/settings.json" "$SETTINGS"
)
```

### 3.4 WSL: discover the bucket and prepare the scripts

The local user reads the role's published bucket name, verifies bucket ownership
and region, and adds it to existing settings. Preparation then copies the inventory,
private host variables and account/region/bucket settings to EC2. It clones GitHub's
**default branch**, so publish the desired code there before running preparation.
`host_vars/<site>.yml` must already contain the website credentials and paths.

```bash
(
set -euo pipefail
export AWS_PROFILE=backup-validator AWS_PAGER=''
umask 077
SETTINGS="$HOME/.config/backup-validator/aws.yml"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ "$ACCOUNT" == "$(jq -r '.aws_account_id' "$SETTINGS")" ]]
REGION=$(jq -er '.aws_region' "$SETTINGS")
ROLE=$(jq -er '.upload_role' "$SETTINGS")
BUCKET=$(aws iam get-role --role-name "$ROLE" --output json \
  | jq -er '[.Role.Tags[]? | select(.Key == "BackupBucket") | .Value] | select(length == 1) | .[0]')
LOCATION=$(aws s3api get-bucket-location --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT" \
  --region "$REGION" --output json | jq -r '.LocationConstraint // "us-east-1" | if . == "EU" then "eu-west-1" else . end')
[[ "$LOCATION" == "$REGION" ]]
WORK_FILE=$(mktemp)
trap 'rm -f -- "$WORK_FILE"' EXIT
jq --arg bucket "$BUCKET" '. + {backup_bucket:$bucket}' "$SETTINGS" > "$WORK_FILE"
install -m 600 "$WORK_FILE" "$SETTINGS"
ansible-playbook aws/prepare-backup-scripts.yml -e @"$SETTINGS"
)
```

### 3.5 WSL, then EC2: authorize website access and run backup/upload

Connect from **WSL**. The block discovers the public IP from the configured tag
and refuses zero or multiple matches. If the website provider restricts source
IPs, authorize the printed EC2 IP before backing up.

```bash
(
set -euo pipefail
export AWS_PROFILE=backup-validator AWS_PAGER=''
SETTINGS="$HOME/.config/backup-validator/aws.yml"
[[ $(aws sts get-caller-identity --query Account --output text) == "$(jq -r '.aws_account_id' "$SETTINGS")" ]]
IP=$(aws ec2 describe-instances --region "$(jq -r '.aws_region' "$SETTINGS")" \
  --filters "Name=tag:Name,Values=$(jq -r '.tag_name' "$SETTINGS")" 'Name=instance-state-name,Values=running' \
  --output json | jq -er '[.Reservations[].Instances[].PublicIpAddress | select(. != null)] | select(length == 1) | .[0]')
printf 'Backup machine IP: %s\n' "$IP"
ssh -i "$(jq -r '.ansible_ssh_private_key_file' "$SETTINGS")" "ubuntu@$IP"
)
```

On **EC2**, install its public key on each website using existing website login
credentials. Substitute that site's SSH user and host. Verify the website host-key
fingerprint before accepting it. If passwords are disabled, install the output of
`cat ~/.ssh/id_rsa.pub` through the hosting provider's SSH-key interface instead.

```bash
ssh-copy-id -i ~/.ssh/id_rsa.pub SITE_USER@SITE_SSH_HOST
ssh -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/id_rsa SITE_USER@SITE_SSH_HOST true
```

On **EC2**, perform the combined backup/upload. Its role supplies AWS credentials;
do not set the workstation's AWS profile here.

```bash
cd /home/ubuntu/backup-validator
ansible-playbook backup-all-sites.yml -e @/home/ubuntu/.config/backup-validator/aws.yml
```

**Checkpoint:** every site finishes successfully. This writes production staging
files and uploads archives. `pipefail` detects either transfer command failing;
`--expected-size` supplies archive size for multipart uploads. Successful upload
alone does not prove recoverability. Stop before moving to downloads.

## 4. Download

No additional AWS permissions are needed: the local user's `ReadOnlyAccess`
already covers listing and reading archives. In **WSL**, use an empty `backups/`
for the first end-to-end test so older local archives cannot be selected later.
Move existing archives aside rather than deleting them.

```bash
AWS_PROFILE=backup-validator ansible-playbook download-latest-backups.yml \
  -e @"$HOME/.config/backup-validator/aws.yml"
```

**Checkpoint:** every site has a newly downloaded archive in `backups/`. See
[download behavior](../README.md#download-latest-backups-from-s3) for selection,
size checking and check mode.

## 5. Restore and verify locally

No AWS setup or credentials are needed for this stage. Complete the
[local restore prerequisites](../README.md#local-restore-prerequisites), including
Docker, private environment-version declarations and Windows hosts mappings.
Then run in **WSL**:

```bash
./wp-local-restore.sh
```

**Checkpoint:** inspect each site's validation report and restored site. See
[validation and artifacts](../README.md#validation-and-artifacts) for what is
checked and its limits. If desired, remove the temporary local environments:

```bash
./wp-local-cleanup.sh
```

Cleanup preserves downloaded archives. Stop before terminating the EC2 machine.

## 6. Terminate

### 6.1 CloudShell: grant scoped termination permission

This permission is added only when needed. It can also be granted early if a
machine must be abandoned after a failed stage; it depends only on stage 1.

```bash
(
set -euo pipefail
umask 077
SETTINGS="$HOME/backup-validator/aws.yml"
ACCOUNT=$(jq -er '.aws_account_id' "$SETTINGS")
REGION=$(jq -er '.aws_region' "$SETTINGS")
USER_NAME=$(jq -er '.iam_user_name' "$SETTINGS")
TAG=$(jq -er '.tag_name' "$SETTINGS")
[[ $(aws sts get-caller-identity --query Account --output text) == "$ACCOUNT" ]]
WORK_FILE=$(mktemp)
trap 'rm -f -- "$WORK_FILE"' EXIT
jq -n --arg resource "arn:aws:ec2:$REGION:$ACCOUNT:instance/*" --arg tag "$TAG" '{
  Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"ec2:TerminateInstances",
  Resource:$resource,Condition:{StringEquals:{"ec2:ResourceTag/Name":$tag}}}]
}' > "$WORK_FILE"
aws iam put-user-policy --user-name "$USER_NAME" --policy-name BackupTermination --policy-document "file://$WORK_FILE"
)
```

### 6.2 WSL: terminate the machine

```bash
AWS_PROFILE=backup-validator ansible-playbook aws/destroy-backup-machine.yml \
  -e @"$HOME/.config/backup-validator/aws.yml"
```

**Checkpoint:** the matching machine is terminated. The playbook handles stopped
machines, refuses multiple matches and succeeds without changes if none match.
Its root disk, machine SSH key and private runtime files are deleted. S3 archives,
network resources, IAM resources, the operator key and local downloads remain for
future runs. Do not run concurrent machine lifecycle commands.

## Repeat runs and changes

For another machine with unchanged settings, rerun 1.6, 2, 3.4–3.5, 4–5 and 6.2.
Previously granted permissions remain in place. Stages control when permissions
are first introduced; they do not revoke permissions between runs.

For a different account, start at 1.1 in that account's CloudShell and use 1.5 to
replace the local profile/settings. For a changed AMI, type, disk size or machine
tag, edit CloudShell settings and rerun 1.4, then download/import settings through
1.5. Refresh 6.1 if the termination scope changes. For site changes, upload the
new `hosts`, rerun 3.2 and 3.4, and adjust 3.3/provider SSH access as necessary.
Changed existing firewall rules require deliberate review; reruns flag conflicts.

Never edit both copies independently: CloudShell owns AWS resource settings;
WSL adds its local SSH path and discovers the bucket. The EC2 settings file is a
runtime snapshot refreshed by 3.4. Keep configuration backups outside Git.
Scheduling, failure notifications, archive retention and stronger SSH host-key
checking are separate operational work; the current upload disables host-key
checking.

## AWS references

- [CloudShell environment](https://docs.aws.amazon.com/cloudshell/latest/userguide/vm-specs.html)
- [EC2 instance-type offerings](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instance-type-offerings.html)
- [S3 bucket creation](https://docs.aws.amazon.com/cli/latest/reference/s3api/create-bucket.html)
- [S3 lifecycle configuration](https://docs.aws.amazon.com/cli/latest/reference/s3api/put-bucket-lifecycle-configuration.html)
- [Reading IAM role metadata and tags](https://docs.aws.amazon.com/cli/latest/reference/iam/get-role.html)

- [Browser login with console credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
- [Boto3 login prerequisites](https://docs.aws.amazon.com/boto3/latest/guide/credentials.html#login-with-console-credentials)
