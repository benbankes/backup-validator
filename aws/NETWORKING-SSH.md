# Networking and SSH setup

Use this guide to create or verify networking for the public-IPv4 EC2 backup
machine. Reuse suitable existing resources instead of recreating them. Follow
sections 1–4 before IAM setup and sections 5–6 after IAM access is configured. Use a
bootstrap administrator for resource creation and the `backup-validator` profile for operation.
Replace uppercase placeholders and use the same region throughout.

## 1. Record the account settings

Choose the account, region, bucket name and operator's current public IPv4 address.
Use `us-east-1` to match the current scripts, unless deliberately changing their
regional assumptions. Verify the account in administrator CloudShell:

```bash
aws sts get-caller-identity
```

Record the resulting VPC, subnet, internet gateway, route table and security group
IDs as you create them. Also record the key-pair name and local private-key path.
Resource IDs must belong to the selected account and region.

## 2. Create the VPC and public subnet

In the AWS account's VPC console, with the intended region selected:

1. Create a VPC named `backup-validator`. Choose a non-overlapping private IPv4
   CIDR; `10.80.0.0/16` is an example, not a required value. Enable DNS resolution
   and DNS hostnames in its VPC settings.
2. Create a subnet named `backup-validator-public` in that VPC, for example
   `10.80.1.0/24`, in one availability zone offering the intended instance type.
   Availability-zone letters need not identify the same physical zone across
   accounts. Select an available zone in the account being configured.
3. Create an internet gateway named `backup-validator` and attach it to this VPC.
4. Create a route table named `backup-validator-public` in the VPC. Retain its
   local route and add destination `0.0.0.0/0` targeting the new internet gateway.
5. Explicitly associate this route table with the new subnet.
6. Keep the default network ACL for this initial setup. Custom ACLs must permit
   the connections below and return traffic, including ephemeral ports.

The launch playbook explicitly requests a public IPv4 address, so subnet-wide
auto-assignment is not required. Internet access requires both that public address
and the internet-gateway route. This design does not need a NAT gateway. See
[AWS internet gateway requirements](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html).

## 3. Create the backup machine's security group

Create `SshSecurityGroup` in the selected VPC. Set these rules:

| Direction | Protocol/port | Source or destination | Purpose |
| --- | --- | --- | --- |
| Inbound | TCP 22 | Operator's current public IPv4 `/32` | WSL/Ansible SSH to the backup machine |
| Outbound | TCP 22 | Each website SSH endpoint's public IPv4 `/32`, or its documented required range | Backups from website servers |
| Outbound | TCP 443 | `0.0.0.0/0` | S3, AWS APIs, GitHub and HTTPS package repositories |
| Outbound | TCP 80 | `0.0.0.0/0` | Package repositories that use HTTP |

Replace the group's default unrestricted outbound rule with the chosen outbound
rules. Resolve the actual `ansible_host` values from your private host variables;
web/CDN addresses are not necessarily the SSH endpoint addresses. Update the
outbound rules if those SSH addresses change. Broader HTTPS destinations are used
because package/GitHub endpoints can change addresses; tighter HTTPS egress would
require additional endpoint/proxy design. Leave the VPC's default DNS resolver
available. Security groups are stateful, so response traffic needs no separate
inbound ephemeral-port rule.

Do not add inbound HTTP, HTTPS or database rules: this machine connects outward
to the website servers. The current workflow uses ordinary SSH with a local key,
so it does not need an EC2 Instance Connect rule. Update the operator `/32` if
their home/VPN public address changes.

## 4. Create the operator-to-backup-machine SSH key

There are two separate SSH relationships. This first key belongs to the operator
and permits login **to EC2**. The key generated on EC2 in step 6 permits login
**from EC2 to the website servers**.

In WSL, generate a new local key at a previously unused path:

```bash
mkdir -p ~/.ssh/backup-validator
chmod 700 ~/.ssh/backup-validator
ssh-keygen -t ed25519 -f ~/.ssh/backup-validator/operator
chmod 600 ~/.ssh/backup-validator/operator
```

Use `ssh-agent` if you protect the private key with a passphrase. In the EC2
console's Key pairs page, choose **Import key pair**, name it
`backup-validator-operator`, and import `operator.pub`. Alternatively, upload
only `operator.pub` to CloudShell and run there:

```bash
aws ec2 import-key-pair --region us-east-1 \
  --key-name backup-validator-operator \
  --public-key-material fileb://operator.pub
```

Only the public key goes to AWS. Keep the private key in WSL, outside this
repository. [AWS key-pair documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/create-key-pairs.html).

## 5. Apply IAM policies and launch with the new settings

Create or select the bucket, then follow the [CloudShell IAM setup](IAM.md).
Use the same account, bucket, subnet, security group and key-pair name in both
guides. Configure the single local profile `backup-validator`.

Create a local Ansible extra-vars file, for example
`/tmp/backup-validator.yml`, with your actual values:

```yaml
aws_region: us-east-1
subnet_id: subnet-REPLACE
security_group: sg-REPLACE
key_name: backup-validator-operator
iam_profile: arn:aws:iam::ACCOUNT_ID:instance-profile/backup-validator-upload
tag_name: backup_creator_tag
backup_bucket: BUCKET_NAME
ansible_ssh_private_key_file: /home/YOUR_USER/.ssh/backup-validator/operator
```

The extra variable `ansible_ssh_private_key_file` overrides the hard-coded key
path in both creation and discovery. Use this file for every controller playbook
run, and preserve a private copy of the account configuration outside `/tmp`.
Run from the repository root:

```bash
AWS_PROFILE=backup-validator ansible-playbook aws/create-backup-machine.yml \
  -e @/tmp/backup-validator.yml
AWS_PROFILE=backup-validator ansible-playbook aws/configure-backup-machine.yml \
  -e @/tmp/backup-validator.yml
AWS_PROFILE=backup-validator ansible-playbook aws/prepare-backup-scripts.yml \
  -e @/tmp/backup-validator.yml
```

The launch playbook waits for SSH, so a timeout here calls for checking the public
IP, route-table association, operator `/32`, key pair and private key. The Ubuntu
AMI's SSH username is `ubuntu`. Verify the machine's SSH host-key fingerprint
through a trusted channel such as the EC2 console system log before accepting it.

## 6. Establish backup-machine-to-website SSH access

Configuration generates `/home/ubuntu/.ssh/id_rsa` and `id_rsa.pub` on EC2.
Preparation copies the private site host variables and clones the repository.
It does not install AWS access keys: uploads should use the EC2 instance role.

1. Record EC2's public IPv4 address. If the website host/provider filters SSH by
   source address, allow that address for TCP 22 at the website end.
2. The current ephemeral public IP can change after stop/start or replacement.
   Update website allowlists each time. If a stable address is required, add an
   Elastic IP allocation/association step and its separate bootstrap permissions
   (`ec2:AllocateAddress`, `ec2:AssociateAddress`; cleanup needs the corresponding
   disassociate/release actions). The present playbook does not manage Elastic IPs.
3. Confirm the initial website login credentials in private `host_vars` are valid.
   `backup-all-sites.yml` first installs EC2's public key into each configured
   website user's `authorized_keys` using those existing credentials. It then
   performs backups. Do not run the whole playbook just to test connectivity.
4. To preflight key access without creating backups, install only EC2's public key
   using the website's authorized administration method. From EC2, verify each
   target with `ssh -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/id_rsa USER@SSH_HOST true`.
   Confirm the website host-key fingerprint before accepting it. Replace USER and
   SSH_HOST with the site's actual settings. Never copy EC2's private key to the
   website servers.
5. On EC2, run `aws sts get-caller-identity` and confirm the uploader assumed-role
   ARN. Then run `ansible-playbook backup-all-sites.yml -e backup_bucket=BUCKET_NAME`
   from `/home/ubuntu/backup-validator` when ready for a real backup. Run the
   downloader locally with the backup-validator profile and the same bucket
   override, then restore and verify every site before enabling scheduled backups.

The upload command currently disables SSH host-key checking; recording verified
host keys is preparation for tightening that behavior, not a claim that this
runbook has changed the command. Scheduling, source-server credential changes,
and allowlist changes remain separate from AWS IAM permissions.

## Bootstrap permissions

Network creation requires only the actions used by your chosen setup: typically
`ec2:CreateVpc`, `ec2:ModifyVpcAttribute`, `ec2:CreateSubnet`,
`ec2:CreateInternetGateway`, `ec2:AttachInternetGateway`, `ec2:CreateRouteTable`,
`ec2:CreateRoute`, `ec2:AssociateRouteTable`, `ec2:CreateSecurityGroup`,
`ec2:AuthorizeSecurityGroupIngress`, `ec2:AuthorizeSecurityGroupEgress`,
`ec2:RevokeSecurityGroupEgress` to replace default egress, `ec2:ImportKeyPair`,
and scoped `ec2:CreateTags`, plus relevant Describe actions. Changing subnet-wide
public-IP assignment additionally needs `ec2:ModifySubnetAttribute`. Keep these
bootstrap permissions separate from the runtime policies.
