# AWS access setup

Use one local AWS profile, `backup-validator`, backed by an IAM user with:

- AWS-managed **ReadOnlyAccess** across the account, including data reads.
- A custom **backup-validator-operations** policy for this repository's writes.

The EC2 backup machine uses a separate upload-only role with temporary credentials.
No local role switching or user access keys on EC2 are needed. Broad read access
also covers discovery, downloads and IAM policy validation/simulation; it is not
limited to the backup bucket. AWS maintains the managed read-only policy.

## Prerequisites

Use AWS CloudShell while signed in as an administrator in the intended account.
The commands below manage IAM; the everyday user does not receive IAM management
permissions. Complete the [README setup sequence](../README.md#aws-setup-order)
first: select networking, create/verify the bucket, and pin an AMI in `aws.yml`.
Customer-managed KMS encryption needs additional key permissions not supplied here.

These commands use standard AWS commercial-region ARNs. Supply your account and
resource IDs through the shared settings file. Upload your local `aws.yml` and
the repository's `hosts` file to CloudShell before running these commands; do not
maintain a separate site list. `hosts` must contain one site hostname per line,
with optional blank/comment lines (the repository's inventory format).
The user, role and policy names below should be dedicated to this repository.
For an existing user or role, unrelated policies are preserved; user group
memberships and access keys are also preserved. These may grant additional
permissions. Reruns update the named custom
policy, uploader trust and uploader inline policy. Other users of those named
resources would also be affected.

## 1. Create or update access in CloudShell

Paste the entire block into **CloudShell Bash**, adjusting only the uploaded file
paths if needed. It checks the account, validates the pinned AMI, creates
missing IAM resources and applies the policies. It stops on errors; IAM changes
are not transactional, so inspect any partial changes before retrying. Temporary
JSON is removed on exit; no generated policy files are maintained in the repo.

```bash
(
set -euo pipefail
export AWS_PAGER=''
umask 077

SETTINGS_FILE="$HOME/aws.yml"
INVENTORY_FILE="$HOME/hosts"
EXPECTED_ACCOUNT=$(jq -er '.aws_account_id' "$SETTINGS_FILE")
REGION=$(jq -er '.aws_region' "$SETTINGS_FILE")
USER_NAME=$(jq -er '.iam_user_name' "$SETTINGS_FILE")
BUCKET=$(jq -er '.backup_bucket' "$SETTINGS_FILE")
SUBNET_ID=$(jq -er '.subnet_id' "$SETTINGS_FILE")
SECURITY_GROUP_ID=$(jq -er '.security_group' "$SETTINGS_FILE")
KEY_NAME=$(jq -er '.key_name' "$SETTINGS_FILE")
INSTANCE_TYPE=$(jq -er '.instance_type' "$SETTINGS_FILE")
MACHINE_TAG=$(jq -er '.tag_name' "$SETTINGS_FILE")
UPLOAD_ROLE=$(jq -er '.upload_role' "$SETTINGS_FILE")
POLICY_NAME=$(jq -er '.iam_policy_name' "$SETTINGS_FILE")
AMI_ID=$(jq -er '.ami_id' "$SETTINGS_FILE")
ROOT_VOLUME_SIZE=$(jq -er '.root_volume_size | select(type == "number" and floor == . and . >= 8 and . <= 16384)' "$SETTINGS_FILE")
[[ -r "$INVENTORY_FILE" ]] || { echo 'Upload the repository hosts file.' >&2; exit 1; }
mapfile -t SITES < <(awk 'NF && $1 !~ /^#/ {print $1}' "$INVENTORY_FILE" | sort -u)
[[ ${#SITES[@]} -gt 0 ]] || { echo 'Inventory is empty.' >&2; exit 1; }
for site in "${SITES[@]}"; do
  [[ "$site" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo "Invalid inventory site: $site" >&2; exit 1; }
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
[[ "$EXPECTED_ACCOUNT" =~ ^[0-9]{12}$ && "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT" ]] || {
  echo 'Set aws_account_id to the intended CloudShell account in the shared settings.' >&2; exit 1;
}
[[ "$BUCKET" != REPLACE* && "$SUBNET_ID" == subnet-* && "$SECURITY_GROUP_ID" == sg-* ]] || {
  echo 'Set the bucket, subnet and security group.' >&2; exit 1;
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

jq -n --arg bucket "$BUCKET" --args \
  '$ARGS.positional | map("arn:aws:s3:::\($bucket)/\(.)/\(.)-*.tar.gz")' \
  "${SITES[@]}" > "$WORK_DIR/objects.json"
jq -n --slurpfile objects "$WORK_DIR/objects.json" '{
  Version: "2012-10-17", Statement: [{
    Sid: "UploadArchives", Effect: "Allow",
    Action: ["s3:PutObject", "s3:AbortMultipartUpload"], Resource: $objects[0]
  }]
}' > "$WORK_DIR/upload.json"
cat > "$WORK_DIR/trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]
}
JSON
cat > "$WORK_DIR/operations-base.json" <<JSON
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
      "Sid": "TerminateBackupMachines", "Effect": "Allow", "Action": "ec2:TerminateInstances",
      "Resource": "$EC2_ARN:instance/*",
      "Condition": {"StringEquals": {"ec2:ResourceTag/Name": "$MACHINE_TAG"}}
    },
    {
      "Sid": "PassUploadRole", "Effect": "Allow", "Action": "iam:PassRole", "Resource": "$ROLE_ARN",
      "Condition": {"StringEquals": {"iam:PassedToService": "ec2.amazonaws.com"}}
    }
  ]
}
JSON
jq --slurpfile upload "$WORK_DIR/upload.json" \
  '.Statement += $upload[0].Statement' "$WORK_DIR/operations-base.json" > "$WORK_DIR/operations.json"

# Validate before changing IAM. Stop for any finding so it can be reviewed.
for policy in upload operations; do
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
aws iam put-role-policy --role-name "$UPLOAD_ROLE" --policy-name BackupUpload \
  --policy-document "file://$WORK_DIR/upload.json"
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
aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN"
printf 'User: %s\nInstance profile: %s\nAllowed AMI: %s\n' "$USER_NAME" "$PROFILE_ARN" "$AMI_ID"
)
```

This setup grants the uploader only S3 upload/abort access; the local user gets those writes
plus the scoped machine operations. Neither gets backup deletion or general IAM
administration from this setup. Provisioning handles the declared configuration;
repairing instance attributes, tags or profiles may require separately reviewed
permissions. The bucket/network/key must already exist.

Rerun this block after changing sites, resources or the selected AMI. Unchanged
policies do not create another version; at the five-version limit an update removes
the oldest nondefault version. IAM propagation may briefly delay use of new roles.

## 2. Configure the single local profile

Reuse an existing access key for the chosen user if available. Otherwise, create
one separately in CloudShell **once**, not on every setup run:

```bash
USER_NAME=$(jq -er '.iam_user_name' "$HOME/aws.yml")
aws iam list-access-keys --user-name "$USER_NAME"
# Run only if you need a new key:
aws iam create-access-key --user-name "$USER_NAME"
```

The second command displays a secret access key only once. Store it privately,
enter it in your local AWS configuration, and do not paste it into this repository
or a conversation. The user name comes from the same uploaded settings file.

In local WSL:

```bash
aws configure --profile backup-validator
aws sts get-caller-identity --profile backup-validator
```

Enter the account's region during configuration. Use this profile for all local
provision/configure/download/verification commands. Do not configure this user's
keys on EC2: the AWS CLI there uses the upload instance role automatically.

## Maintenance

Return to the [README operational commands](../README.md#aws-operations) to create,
configure, back up, download, verify or destroy. All use the same settings file.
Rerun this IAM block after editing sites in `hosts` or changing deployment settings;
upload the updated files first. Changing a local file does not automatically change
AWS permissions. IAM validation does not replace a complete backup/restore test.

## References

- [AWS ReadOnlyAccess](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/ReadOnlyAccess.html)
- [Managed policy versioning](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_managed-versioning.html)
- [EC2 permission scopes](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html)
