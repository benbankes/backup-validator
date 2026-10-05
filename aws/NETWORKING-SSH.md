# Networking and SSH reference

Follow the [chronological setup guide](SETUP.md) for commands. Networking is
introduced in [provisioning, 1.3](SETUP.md#13-cloudshell-create-networking-and-import-the-public-key);
website access is introduced only in
[backup/upload, 3.3](SETUP.md#33-cloudshell-allow-outbound-website-ssh).

The machine uses a dedicated public subnet, internet gateway and public IPv4
address. It needs no NAT gateway. Its security group initially allows inbound
TCP 22 from the operator's public IPv4 `/32`, and outbound TCP 80/443 for package
installation. Backup setup adds outbound TCP 22 to the website SSH servers'
IPv4 CIDRs. Website addresses must come from `ansible_host`, not a CDN hostname.

Keep the default network ACL or configure return traffic explicitly. Custom ACLs
are not validated by the setup commands. DNS must remain available through the
VPC resolver. Choose CIDRs that do not overlap connected networks and an
availability zone that offers the selected instance type.

| Connection | Private key location | Public key destination |
| --- | --- | --- |
| WSL → EC2 | `~/.ssh/backup-validator/operator` in WSL | Imported EC2 key pair during provisioning |
| EC2 → websites | `/home/ubuntu/.ssh/id_rsa` on EC2 | Website authorized keys during backup setup |

Keep private keys at their source. The EC2 website key is created during machine
configuration; it is not the workstation's operator key. Use the hosting provider's
SSH-key interface when website password login is unavailable. The backup playbook
also installs the public key using existing credentials, but running it performs
real backup/upload work.

A new machine or stop/start can change its public IP. Update hosting-provider
allowlists when that happens; an Elastic IP would require separate setup and
permissions. If the operator's public IP changes, review and update the inbound
rule. Website IP changes likewise require an outbound-rule update.

Bootstrap discovers resources by `BackupNetwork` tags (with optional explicit
VPC/subnet IDs). It refuses duplicate matches and conflicting routes, firewall
rules or public keys. It does not silently repurpose an existing shared subnet.
After partial failure, inspect the created resources before retrying. Rerunning
with unchanged inputs reuses resources; changed firewall rules require review.

The upload currently disables SSH host-key checking, and Ansible's repository
configuration also disables it. Verifying host keys and enabling enforcement is
separate hardening work. Terminating EC2 deletes its root disk and website private
key but retains the network, EC2 key-pair registration and workstation key.

## References

- [Internet gateway requirements](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html)
- [Read existing EC2 public keys](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-key-pairs.html)
- [Route-table queries](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-route-tables.html)
