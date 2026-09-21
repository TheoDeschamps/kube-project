# Infra bootstrap — Ansible

Provisions a 3-node kubeadm cluster (kube-1 control plane, kube-2/kube-3
workers) on the AWS VMs provided for the Kube project. Nodes run Amazon
Linux 2023 (arm64).

## Prerequisites

- AWS CLI v2 configured for SSO (`aws sso login`) with access to the group's
  EC2 instances and SSM. Run everything from a Linux control machine (WSL
  Ubuntu works) — Ansible does not support a native Windows control node.
- `session-manager-plugin` installed locally.
- Python 3 with `boto3`/`botocore` (`pip install boto3 botocore`).
- Ansible >= 2.15, with collections from `requirements.yml`:
  `ansible-galaxy collection install -r requirements.yml`.

## First-time setup (once per environment)

1. Run the discovery steps in `DISCOVERY.md` to confirm instance IDs, IPs and
   the OS family, and to tag the instances `Project=kube`.
2. Generate the project SSH keypair and push it to the 3 VMs:
   ```bash
   ssh-keygen -t ed25519 -f secrets/kube_project_id_ed25519 -C kube-project -N ""
   ./scripts/bootstrap-ssh-keys.sh <kube-1-id> <kube-2-id> <kube-3-id>
   ```

## Provisioning the cluster

```bash
ansible-inventory --graph        # sanity check: control_plane + workers groups
ansible all -m ping               # sanity check: SSH connectivity
ansible-playbook playbooks/site.yml
```
The playbook is safe to re-run — it's idempotent and won't disrupt a running
cluster.

## Known operational caveats

- `kube-2`/`kube-3` have no stable public IP, so nothing external should
  target them directly. Their private VPC IP is expected to remain stable
  across the nightly shutdown/restart, but if the dynamic inventory
  (`inventory/aws_ec2.yml`) ever returns a stale IP after a restart, re-run
  `ansible-inventory --graph` to confirm the current addresses before
  re-running the playbook. A static `inventory.ini` fallback can be
  substituted for the dynamic plugin if AWS API access from the control
  machine becomes unavailable — see the spec at
  `docs/superpowers/specs/2026-09-21-infra-bootstrap-design.md`.
- The instances can occasionally fail to start with
  `InsufficientInstanceCapacity` (observed for `t4g.medium` in `eu-west-3a`).
  This is an AWS-side capacity shortage, not fixable from the client side —
  retry later.
