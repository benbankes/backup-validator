# IAM reference

For commands, follow the [chronological setup guide](SETUP.md). This page explains
the resulting access; it is not a second setup procedure.

Use one local profile, `backup-validator`, backed by browser login as a dedicated IAM user. No permanent access key is
required. The EC2
machine uses a dedicated role and instance profile with the same name. No user
access keys are installed on EC2.

| Introduced at | Identity | Permissions and scope |
| --- | --- | --- |
| [Provisioning, 1.4](SETUP.md#14-cloudshell-create-provisioning-access) | Local user | AWS-managed `ReadOnlyAccess` and `SignInLocalDevelopmentAccess`, plus managed `backup-validator-operations` for the pinned AMI, subnet, security group, key pair, instance type, root disk limit and profile |
| Provisioning, 1.4 | EC2 role | Trust for `ec2.amazonaws.com`; no S3 permissions yet |
| [Backup/upload, 3.2](SETUP.md#32-cloudshell-grant-archive-upload-access-and-publish-the-bucket-name) | User and EC2 role | Inline `BackupUpload`: `s3:PutObject` and `s3:AbortMultipartUpload` on `<bucket>/*`, independent of the site inventory |
| Download | Local user | Existing read access covers S3 list/get operations; no new policy |
| Local restore/verification | None | No AWS access |
| [Termination, 6.1](SETUP.md#61-cloudshell-grant-scoped-termination-permission) | Local user | Inline `BackupTermination`: `ec2:TerminateInstances` restricted to region/account and the configured Name tag |

The provisioning write policy permits `ec2:RunInstances`, `ec2:CreateTags` only
during launch, and `iam:PassRole` only for the configured role and EC2 service.
It does not allow arbitrary instance repairs, retagging or profile replacement.
The selected gp3 root-volume size is an upper bound in IAM. IAM does not limit the
number of launches; the playbook enforces a unique machine tag match.

Broad account-wide read access is intentional, including data reads. It is not
least privilege for downloads alone. AWS maintains `ReadOnlyAccess`; repository
write access is scoped separately. Neither identity receives backup deletion or
IAM administration from these policies. Existing unrelated policies or user group
memberships may grant more access and are preserved.

Administrator CloudShell performs resource creation and IAM updates. The everyday
user is not granted VPC, bucket or IAM administration. The setup uses commercial
AWS ARNs and SSE-S3; customer-managed KMS keys require additional key permissions.
Organization policies, permission boundaries and resource policies can further
restrict access. Live testing is required to confirm the account's effective access.

Provisioning-policy updates compare content before creating a managed-policy
version. At the five-version limit, changed policies replace the oldest nondefault
version. Later upload/termination policies are separate, so rerunning provisioning
does not erase them. The upload policy covers all object paths in the dedicated
backup bucket, including overwrites, so adding a site requires no IAM update.
The EC2 upload role receives no read/delete access from this policy. The local
user retains its separate broad read access. Unrelated inline policies count
toward the IAM user's aggregate inline-policy limit.

Permissions remain after a stage completes; the staged guide adds them when first
needed. Rerun the relevant stage after changing its inputs, and allow for IAM
propagation before first use. The role's `BackupBucket` tag publishes the established
destination to the local read-only user; it contains no credentials and grants no
permissions by itself.

## References

- [AWS ReadOnlyAccess](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/ReadOnlyAccess.html)
- [Managed policy versioning](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_managed-versioning.html)
- [EC2 permission scopes](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html)
- [IAM quotas](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html)

Console access is created in setup step 1.4 only if missing; reruns preserve the
password. `SignInLocalDevelopmentAccess` enables CLI login, while the resource
policies still define what the user can do. Step 1.5 checks both CLI and SDK identity
as the operator. The SDK installer supplies Boto3 with AWS CRT in `.venv/aws` for
Ansible's local AWS modules. EC2 continues using its instance role.

- [SignInLocalDevelopmentAccess](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/SignInLocalDevelopmentAccess.html)
