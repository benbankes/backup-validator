# Setup

- Use steps at https://docs.ansible.com/ansible/latest/user_guide/intro_dynamic_inventory.html#example-aws-ec2-external-inventory-script
- Ensure EC2 host is accessible over SSH via a Security Group

As a development aid, see the AWS documentation at https://docs.ansible.com/ansible/2.5/scenario_guides/guide_aws.html

### Documentation

To perform the monthly backup routine

- `cd` into the `aws` folder
- run `ansible-playbook monthly-backup-routine.yml`
