# Infra bootstrap — Ansible

Provisions a 3-node kubeadm cluster (kube-1 control plane, kube-2/kube-3
workers) on the AWS VMs provided for the Kube project. Nodes run Amazon
Linux 2023 (arm64).

## Important: Ansible runs on kube-1, not your laptop

The security group only opens ports 80/443 to the internet — port 22 is
never public, by design (the subject explicitly routes access through SSM
instead of public SSH). The student IAM role also only allows the base
interactive SSM session (`ssm:SendCommand` and the SSM SSH/port-forwarding
documents are denied). So:

- Your laptop **cannot** SSH into any node directly.
- **Ansible itself runs on `kube-1`**, reaching `kube-2`/`kube-3` over their
  private VPC IPs (already allowed by the security group's self-referencing
  rule), using a static inventory (`inventory/hosts.ini`).
- Files get onto `kube-1` by `git clone`-ing this repo from GitHub (`kube-1`
  has outbound internet access) — not by `scp` from the laptop.

## Prerequisites

- AWS CLI v2 configured for SSO (`aws sso login`) — used from your laptop
  only for discovery and opening SSM sessions, never to reach the nodes
  directly.
- `session-manager-plugin` installed locally, to open
  `aws ssm start-session --target <instance-id>`.

## First-time setup (once per environment)

1. Run the discovery steps in `DISCOVERY.md` to confirm instance IDs, IPs
   and the OS family, and to tag the instances `Project=kube`.
2. Generate the project SSH keypair **locally** (`secrets/` is gitignored):
   ```bash
   ssh-keygen -t ed25519 -f secrets/kube_project_id_ed25519 -C kube-project -N ""
   ```
3. Deploy the public key to all 3 nodes via an interactive SSM session (the
   automated `scripts/bootstrap-ssh-keys.sh` needs `ssm:SendCommand`, which
   the student role does not have — do this manually instead):
   ```bash
   aws ssm start-session --target <instance-id>
   ```
   Inside the session (connects as `ssm-user`):
   ```bash
   sudo mkdir -p /home/ec2-user/.ssh
   echo '<contents of secrets/kube_project_id_ed25519.pub>' | sudo tee -a /home/ec2-user/.ssh/authorized_keys
   sudo sort -u -o /home/ec2-user/.ssh/authorized_keys /home/ec2-user/.ssh/authorized_keys
   sudo chown -R ec2-user:ec2-user /home/ec2-user/.ssh
   sudo chmod 700 /home/ec2-user/.ssh
   sudo chmod 600 /home/ec2-user/.ssh/authorized_keys
   ```
   Repeat for `kube-1`, `kube-2`, `kube-3`.
4. Push this repo to a GitHub remote (public, so `kube-1` can clone it with
   no extra auth setup).
5. Open an SSM session on `kube-1`, switch to `ec2-user` (has passwordless
   sudo on this AMI), clone the repo, and copy the **private** key onto
   `kube-1` (paste its contents the same way as the public key above, into
   `~/kube-project/infra/ansible/secrets/kube_project_id_ed25519`, then
   `chmod 600` it):
   ```bash
   aws ssm start-session --target <kube-1-instance-id>
   sudo su - ec2-user
   git clone https://github.com/<you>/kube-project.git
   cd kube-project/infra/ansible
   mkdir -p secrets
   # paste the private key into secrets/kube_project_id_ed25519, then:
   chmod 600 secrets/kube_project_id_ed25519
   ```
6. Install Ansible and its collections **on kube-1**:
   ```bash
   sudo dnf install -y ansible-core
   ansible-galaxy collection install -r requirements.yml
   ```

## Provisioning the cluster

From the SSM session on `kube-1`, as `ec2-user`, in `~/kube-project/infra/ansible`:

```bash
ansible-inventory --graph        # sanity check: control_plane + workers groups
ansible all -m ping               # sanity check: connectivity (kube-1 local, kube-2/3 over SSH)
ansible-playbook playbooks/site.yml
```
The playbook is safe to re-run — it's idempotent and won't disrupt a running
cluster.

## Access over Tailscale (day-to-day SSH)

SSM sessions work but are clunky for everyday use (no scp, no ProxyJump, one
command at a time). Tailscale gives normal `ssh`/`scp` access instead,
without opening anything in the security group — it tunnels over its own
encrypted network, independent of the VPC.

1. **On `kube-1`** (over an SSM session, as `ec2-user`):
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up --advertise-tags=tag:kube-project
   ```
   Open the URL it prints to link the device to your tailnet, tagged
   `tag:kube-project` (keep it a dedicated tag — don't reuse a personal one,
   so this stays separate from any of your own devices on the same tailnet).
2. **In your tailnet's ACL** (`https://login.tailscale.com/admin/acls`), add
   a grant allowing your own device(s) to reach it, e.g.:
   ```json
   {"src": ["autogroup:member"], "dst": ["tag:kube-project"], "ip": ["*"]}
   ```
   Careful: **once a device itself carries a tag, it no longer matches
   `autogroup:member`** as a source — it's only reachable by rules that name
   its tag explicitly. If your own machine is tagged, use that tag as `src`
   instead of `autogroup:member`.
3. **Install the Tailscale client** on your own machine and sign in to the
   same tailnet.
4. **SSH config**: copy [`ssh-config.example`](ssh-config.example) into your
   own `~/.ssh/config` (or `C:\Users\<you>\.ssh\config` on Windows), and
   replace `<PATH_TO_PRIVATE_KEY>` with your local path to
   `secrets/kube_project_id_ed25519`. Then `ssh kube1` / `ssh kube2` /
   `ssh kube3` just work (kube2/kube3 are reached via a `ProxyJump` through
   kube1, since only kube1 is on Tailscale and they have no stable public
   IP).
   - **Windows only**: the OpenSSH client rejects world-readable files.
     After creating/editing the config or key, run:
     ```powershell
     icacls "<path>" /inheritance:r
     icacls "<path>" /grant:r "$($env:USERNAME):(F)"
     ```
5. **Sharing with teammates**: don't add them to your whole tailnet (that
   would expose your own personal devices too). Instead, use Tailscale's
   per-device **"Share"** feature (admin console → the `ip-10-0-0-49`
   device → Share) to give each teammate access to just that one machine.

## Known operational caveats

- `kube-2`/`kube-3`'s private IPs are recorded in `inventory/hosts.ini`. If
  they change after the nightly shutdown/restart (to be confirmed in
  practice — the subject says private IPs are stable "inside the VPC"),
  update that file by hand before re-running the playbook.
- The instances can occasionally fail to start with
  `InsufficientInstanceCapacity` (observed for `t4g.medium` in `eu-west-3a`,
  including one instance that failed to start on its own for a while even
  after the others succeeded). This is an AWS-side capacity shortage, not
  fixable from the client side — retry later, or escalate to module staff
  if it persists, since other groups sharing the same capacity pool are
  likely affected too.
- To pull later changes made to this repo from your laptop, run
  `git pull` inside `~/kube-project` on `kube-1` (over its own SSM session).
