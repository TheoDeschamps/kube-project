# Infra Access & Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get reliable Ansible access to the 3 AWS VMs and provision a working, idempotent, reproducible 3-node kubeadm Kubernetes cluster (`kube-1` control plane + `kube-2`/`kube-3` workers) with the Calico CNI.

**Architecture:** A discovery pass records instance IDs/IPs/tags. The project SSH keypair's public half is deployed to all 3 VMs manually through an interactive SSM session (`ssm:SendCommand` and the SSM SSH/port-forwarding documents are all IAM-denied for the student role — only the base interactive session is permitted). **Ansible itself runs on `kube-1`, not the operator's laptop** — the security group only opens ports 80/443 to the internet (port 22 is never public, by design), so the laptop cannot reach any node over SSH at all. `kube-1` reaches `kube-2`/`kube-3` over their private VPC IPs, already permitted by the security group's self-referencing "allow all" rule; the project's private key is copied onto `kube-1` for that purpose. `kube-1` has outbound internet access, so it clones this repo from a public GitHub mirror to get the playbook. A static inventory lists `kube-2`/`kube-3`'s private IPs (`kube-1` manages itself via `ansible_connection: local`) — no AWS credentials are stored on `kube-1`. Roles are applied in order: OS prep (`common`) → container runtime (`containerd`) → Kubernetes packages (`kube-pkgs`) → cluster init on the control plane (`kubeadm-init` + `calico`) → worker join (`kubeadm-join`).

**Tech Stack:** Ansible (`amazon.aws`, `community.general`, `ansible.posix` collections), AWS CLI v2 + SSM, kubeadm, containerd, Calico CNI, bash.

**Spec:** [docs/superpowers/specs/2026-09-21-infra-bootstrap-design.md](../specs/2026-09-21-infra-bootstrap-design.md)

## Global Constraints

- Kubernetes distribution: kubeadm (vanilla), version **1.31** (`kubernetes_minor_version: "1.31"`).
- CNI: **Calico**, version **v3.28.0**.
- Target OS confirmed by discovery (2026-09-21): **Amazon Linux 2023, arm64** (`t4g.medium` instances) — dnf/rpm-based, not apt. The `containerd` and `kube-pkgs` roles (Tasks 5–6) below target dnf.
- SSH user on the VMs confirmed: **`ec2-user`** (Amazon Linux default, not `ubuntu`).
- No plaintext secret (private key, kubeconfig, join token) is ever committed to git — all live under paths listed in `.gitignore` (Task 2).
- The playbook must be safely re-runnable without breaking an existing cluster (idempotence), per the spec's "torn down and rebuilt reproducibly" requirement.
- All file paths below are relative to the repo root (`D:\Projet Kube`), monorepo layout: `infra/ansible/...` holds everything in this plan.

## Revision note (2026-09-21) — read before Tasks 2–3

Real infra discovery invalidated two assumptions baked into the tasks below:

1. **`ssm:SendCommand` and the SSM SSH/port-forwarding documents are IAM-denied** for the student role — only the base interactive `ssm:StartSession` works. Task 2's automated `bootstrap-ssh-keys.sh` script (using `send-command`) **does not work**; the public key was instead pasted manually into `/home/ec2-user/.ssh/authorized_keys` on each node through an interactive `aws ssm start-session` shell (connects as `ssm-user`, use `sudo` to write to `ec2-user`'s home).
2. **The security group never opens port 22 to the internet** (only 80/443) — this is deliberate, matching the subject's "SSM instead of public SSH". The laptop cannot reach any node over SSH, so **Ansible runs on `kube-1` itself**, not the laptop. Task 3's dynamic-inventory/ProxyJump design is superseded by: a static inventory on `kube-1` (`kube-2`/`kube-3` by private IP, `kube-1` via `ansible_connection: local`), the project's private key copied onto `kube-1`, and this repo cloned onto `kube-1` from a public GitHub mirror (`kube-1` has outbound internet access; the laptop cannot push files to it directly either).

Tasks 4–9 (the roles and the site playbook) are unaffected — they still apply the same way, just executed from an `ansible-playbook` running on `kube-1` against a local static inventory instead of from the laptop against a dynamic one. See the spec's revised "Transport Ansible" and "Inventaire" sections for the full rationale.

---

## File Structure

```
infra/ansible/
├── ansible.cfg
├── requirements.yml
├── DISCOVERY.md
├── README.md
├── inventory/
│   └── aws_ec2.yml
├── group_vars/
│   ├── all.yml
│   └── workers.yml
├── roles/
│   ├── common/tasks/main.yml
│   ├── containerd/{tasks,handlers}/main.yml
│   ├── kube-pkgs/tasks/main.yml
│   ├── kubeadm-init/tasks/main.yml
│   ├── calico/tasks/main.yml
│   └── kubeadm-join/tasks/main.yml
├── playbooks/
│   └── site.yml
├── scripts/
│   └── bootstrap-ssh-keys.sh
├── secrets/         (gitignored — holds the project SSH keypair)
└── fetched/          (gitignored — holds kubeconfig + join command pulled from kube-1)
```

---

### Task 1: AWS discovery & tagging

**Files:**
- Create: `infra/ansible/DISCOVERY.md`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: recorded instance IDs, public/private IPs and AMI family for `kube-1`/`kube-2`/`kube-3` (used as script arguments in Task 2); an AWS tag `Project=kube` applied to all 3 instances (used as the inventory filter in Task 3).

- [ ] **Step 1: Authenticate and list instances**

Run:
```bash
aws sso login
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=kube-1,kube-2,kube-3" \
  --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,Public:PublicIpAddress,Private:PrivateIpAddress,AMI:ImageId,State:State.Name}" \
  --output table
```
Expected: a table listing 3 running instances. If the `Name` tag filter returns nothing, drop the filter and identify the 3 instances by size/VPC instead, then check what tags they actually carry.

- [ ] **Step 2: Confirm the OS family**

Run:
```bash
aws ec2 describe-images --image-ids <AMI-ID-from-step-1> --query "Images[0].{Name:Name,Platform:PlatformDetails}"
```
Expected: name containing `ubuntu`. If it's a different distro, note it — the `containerd`/`kube-pkgs` roles (Tasks 5–6) target apt/Ubuntu and must be adapted otherwise.

- [ ] **Step 3: Ensure a consistent project tag**

For each instance ID that doesn't already carry `Project=kube`:
```bash
aws ec2 create-tags --resources <instance-id> --tags Key=Project,Value=kube
```

- [ ] **Step 4: Confirm SSM connectivity to all 3 instances**

Run for each instance ID:
```bash
aws ssm start-session --target <instance-id>
```
Expected: an interactive shell opens for all 3. Exit each session with `exit`. If any fails, the SSM agent or IAM permissions need fixing before continuing — this blocks every later task.

- [ ] **Step 5: Check inter-node SSH reachability at the security-group level**

From within an SSM session on `kube-1`:
```bash
nc -zv <kube-2-private-ip> 22
nc -zv <kube-3-private-ip> 22
```
Expected: both succeed. If refused, the security group needs an inbound rule on port 22 from the VPC CIDR — note this in `DISCOVERY.md` as a manual fix required before Task 2's verification step.

- [ ] **Step 6: Write DISCOVERY.md**

```markdown
# Discovery notes

| Name    | Instance ID   | Public IP | Private IP | AMI            |
|---------|---------------|-----------|------------|----------------|
| kube-1  | i-xxxxxxxx    | x.x.x.x   | 10.x.x.x   | ubuntu-...     |
| kube-2  | i-xxxxxxxx    | (varies)  | 10.x.x.x   | ubuntu-...     |
| kube-3  | i-xxxxxxxx    | (varies)  | 10.x.x.x   | ubuntu-...     |

- SSH user: ubuntu
- Project tag applied: yes
- Inter-node SSH (22) reachable from kube-1 to kube-2/3: yes/no (fixed how, if not)
```
Fill in with the real values gathered above.

- [ ] **Step 7: Commit**

```bash
git add infra/ansible/DISCOVERY.md
git commit -m "infra(ansible): record AWS discovery notes for kube-1/2/3

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: SSH key bootstrap via SSM

**Files:**
- Create: `.gitignore` (repo root)
- Create: `infra/ansible/scripts/bootstrap-ssh-keys.sh`
- Create: `infra/ansible/secrets/.gitkeep`

**Interfaces:**
- Consumes: instance IDs and SSH user from `DISCOVERY.md` (Task 1).
- Produces: a reachable SSH keypair at `infra/ansible/secrets/kube_project_id_ed25519[.pub]` (referenced by `ansible_ssh_private_key_file` in Task 3's `group_vars/all.yml`); working direct SSH to `kube-1` and jumped SSH to `kube-2`/`kube-3`.

- [ ] **Step 1: Write the root `.gitignore`**

```gitignore
infra/ansible/secrets/
infra/ansible/fetched/
```

- [ ] **Step 2: Write the bootstrap script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Pushes the project's SSH public key onto the given EC2 instances via SSM,
# so Ansible can connect over normal SSH afterwards.
#
# Prerequisites: aws cli v2 configured (`aws sso login`), session-manager-plugin
# installed, and a keypair generated at ../secrets/kube_project_id_ed25519[.pub].
#
# Usage: ./bootstrap-ssh-keys.sh <instance-id-1> <instance-id-2> <instance-id-3>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_KEY_PATH="${SCRIPT_DIR}/../secrets/kube_project_id_ed25519.pub"
SSH_USER="ec2-user"
INSTANCE_IDS=("$@")

if [ ${#INSTANCE_IDS[@]} -eq 0 ]; then
  echo "Usage: $0 <instance-id-1> <instance-id-2> <instance-id-3>" >&2
  exit 1
fi

if [ ! -f "$PUBLIC_KEY_PATH" ]; then
  echo "Public key not found at $PUBLIC_KEY_PATH. Generate it first with:" >&2
  echo "  ssh-keygen -t ed25519 -f ${SCRIPT_DIR}/../secrets/kube_project_id_ed25519 -C kube-project -N ''" >&2
  exit 1
fi

PUBLIC_KEY="$(cat "$PUBLIC_KEY_PATH")"

for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
  echo "Pushing SSH key to ${INSTANCE_ID}..."
  aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "Deploy project SSH key" \
    --parameters "commands=[\"mkdir -p /home/${SSH_USER}/.ssh\",\"echo '${PUBLIC_KEY}' >> /home/${SSH_USER}/.ssh/authorized_keys\",\"sort -u -o /home/${SSH_USER}/.ssh/authorized_keys /home/${SSH_USER}/.ssh/authorized_keys\",\"chown -R ${SSH_USER}:${SSH_USER} /home/${SSH_USER}/.ssh\",\"chmod 700 /home/${SSH_USER}/.ssh\",\"chmod 600 /home/${SSH_USER}/.ssh/authorized_keys\"]" \
    --output text
done

echo "Done. Wait a few seconds for the SSM commands to complete, then verify with:"
echo "  ssh -i ${SCRIPT_DIR}/../secrets/kube_project_id_ed25519 ${SSH_USER}@<kube-1-public-ip>"
```

Note: `mkdir -p /home/ec2-user/.ssh` may fail silently if `.ssh` already exists with different ownership on Amazon Linux — the script's `chown`/`chmod` steps afterward correct this regardless.

- [ ] **Step 3: Make it executable and generate the keypair**

```bash
chmod +x infra/ansible/scripts/bootstrap-ssh-keys.sh
touch infra/ansible/secrets/.gitkeep
ssh-keygen -t ed25519 -f infra/ansible/secrets/kube_project_id_ed25519 -C kube-project -N ""
```

- [ ] **Step 4: Run the script with the 3 instance IDs from DISCOVERY.md**

```bash
./infra/ansible/scripts/bootstrap-ssh-keys.sh <kube-1-id> <kube-2-id> <kube-3-id>
```
Expected: 3 successful `send-command` invocations (a command ID printed for each).

- [ ] **Step 5: Verify direct SSH to kube-1**

```bash
ssh -i infra/ansible/secrets/kube_project_id_ed25519 ec2-user@<kube-1-public-ip> echo ok
```
Expected: prints `ok`.

- [ ] **Step 6: Verify jumped SSH to kube-2 and kube-3**

```bash
ssh -i infra/ansible/secrets/kube_project_id_ed25519 \
  -o ProxyJump=ec2-user@<kube-1-public-ip> \
  ec2-user@<kube-2-private-ip> echo ok
ssh -i infra/ansible/secrets/kube_project_id_ed25519 \
  -o ProxyJump=ec2-user@<kube-1-public-ip> \
  ec2-user@<kube-3-private-ip> echo ok
```
Expected: both print `ok`. If refused, revisit Task 1 Step 5 (security group).

- [ ] **Step 7: Commit**

```bash
git add .gitignore infra/ansible/scripts/bootstrap-ssh-keys.sh infra/ansible/secrets/.gitkeep
git commit -m "infra(ansible): add SSM-based SSH key bootstrap script

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: Ansible scaffolding & dynamic inventory

**Files:**
- Create: `infra/ansible/ansible.cfg`
- Create: `infra/ansible/requirements.yml`
- Create: `infra/ansible/inventory/aws_ec2.yml`
- Create: `infra/ansible/group_vars/all.yml`
- Create: `infra/ansible/group_vars/workers.yml`

**Interfaces:**
- Consumes: `Project=kube` tag and `Name` tags (Task 1); SSH keypair path (Task 2).
- Produces: two inventory groups, `control_plane` (host `kube-1`) and `workers` (hosts `kube-2`, `kube-3`); variables `ansible_user`, `ansible_ssh_private_key_file`, `kubernetes_minor_version`, `kubernetes_full_version`, `pod_network_cidr`, `calico_version`, `control_plane_endpoint` — all consumed by every later role.

- [ ] **Step 1: Write `requirements.yml`**

```yaml
collections:
  - name: amazon.aws
    version: ">=7.0.0"
  - name: community.general
  - name: ansible.posix
```

- [ ] **Step 2: Install collections and their Python dependencies**

```bash
cd infra/ansible
ansible-galaxy collection install -r requirements.yml
pip install boto3 botocore
```
Expected: collections install without error.

- [ ] **Step 3: Write `ansible.cfg`**

```ini
[defaults]
inventory = inventory/aws_ec2.yml
host_key_checking = False
retry_files_enabled = False
interpreter_python = auto_silent

[inventory]
enable_plugins = amazon.aws.aws_ec2, ansible.builtin.ini
```

- [ ] **Step 4: Write the dynamic inventory config**

`infra/ansible/inventory/aws_ec2.yml`:
```yaml
plugin: amazon.aws.aws_ec2
regions:
  - eu-west-3
filters:
  tag:Project: kube
  instance-state-name: running
hostnames:
  - tag:Name
compose:
  ansible_host: "(public_ip_address if (tags.Name | default('')) == 'kube-1' else private_ip_address)"
groups:
  control_plane: "(tags.Name | default('')) == 'kube-1'"
  workers: "(tags.Name | default('')) in ['kube-2', 'kube-3']"
```
Adjust `regions` to match the real AWS region recorded in `DISCOVERY.md` if different from `eu-west-3`.

- [ ] **Step 5: Write `group_vars/all.yml`**

```yaml
ansible_user: ec2-user
ansible_ssh_private_key_file: "{{ playbook_dir }}/../secrets/kube_project_id_ed25519"
kubernetes_minor_version: "1.31"
pod_network_cidr: "192.168.0.0/16"
calico_version: "v3.28.0"
control_plane_endpoint: "{{ hostvars['kube-1']['ansible_host'] }}"
```

- [ ] **Step 6: Write `group_vars/workers.yml`**

```yaml
ansible_ssh_common_args: "-o ProxyJump={{ ansible_user }}@{{ hostvars['kube-1']['ansible_host'] }}"
```

- [ ] **Step 7: Verify the inventory resolves correctly**

```bash
cd infra/ansible
ansible-inventory --graph
```
Expected output shape:
```
@all:
  |--@control_plane:
  |  |--kube-1
  |--@workers:
  |  |--kube-2
  |  |--kube-3
```

- [ ] **Step 8: Verify connectivity through the inventory**

```bash
ansible all -m ping
```
Expected: `kube-1`, `kube-2`, `kube-3` all return `SUCCESS` with `"ping": "pong"`.

- [ ] **Step 9: Commit**

```bash
git add infra/ansible/ansible.cfg infra/ansible/requirements.yml infra/ansible/inventory/aws_ec2.yml infra/ansible/group_vars/
git commit -m "infra(ansible): add dynamic AWS inventory and base group vars

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: `common` role (OS prep)

**Files:**
- Create: `infra/ansible/roles/common/tasks/main.yml`
- Create: `infra/ansible/playbooks/site.yml`

**Interfaces:**
- Consumes: inventory groups `control_plane`/`workers` (Task 3).
- Produces: swap disabled, `overlay`/`br_netfilter` kernel modules loaded, required sysctl params set on all 3 nodes — prerequisite state for the `containerd` role (Task 5).

- [ ] **Step 1: Write the `common` role**

`infra/ansible/roles/common/tasks/main.yml`:
```yaml
---
- name: Disable swap
  ansible.builtin.command: swapoff -a
  changed_when: false

- name: Remove swap entry from /etc/fstab
  ansible.builtin.lineinfile:
    path: /etc/fstab
    regexp: '^\S+\s+\S+\s+swap\s+'
    state: absent

- name: Load required kernel modules
  community.general.modprobe:
    name: "{{ item }}"
    state: present
  loop:
    - overlay
    - br_netfilter

- name: Persist kernel modules across reboots
  ansible.builtin.copy:
    dest: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter
    mode: "0644"

- name: Set required sysctl params
  ansible.posix.sysctl:
    name: "{{ item.name }}"
    value: "{{ item.value }}"
    sysctl_set: true
    state: present
    reload: true
  loop:
    - { name: net.bridge.bridge-nf-call-iptables, value: "1" }
    - { name: net.bridge.bridge-nf-call-ip6tables, value: "1" }
    - { name: net.ipv4.ip_forward, value: "1" }

- name: Install kubeadm/kubelet runtime prerequisites
  ansible.builtin.dnf:
    name:
      - iptables
      - conntrack-tools
      - socat
    state: present
    update_cache: true
```

- [ ] **Step 2: Write the initial site playbook**

`infra/ansible/playbooks/site.yml`:
```yaml
---
- name: Prepare all nodes
  hosts: all
  become: true
  roles:
    - common
```

- [ ] **Step 3: Run the playbook**

```bash
cd infra/ansible
ansible-playbook playbooks/site.yml
```
Expected: `PLAY RECAP` shows 0 `failed`/`unreachable` for all 3 hosts.

- [ ] **Step 4: Verify the effects**

```bash
ansible all -m command -a "swapon -s"
ansible all -m command -a "sysctl net.ipv4.ip_forward"
```
Expected: first command prints nothing (no active swap); second prints `net.ipv4.ip_forward = 1` for all 3 hosts.

- [ ] **Step 5: Commit**

```bash
git add infra/ansible/roles/common infra/ansible/playbooks/site.yml
git commit -m "infra(ansible): add common role for kubeadm OS prerequisites

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 5: `containerd` role

**Files:**
- Create: `infra/ansible/roles/containerd/tasks/main.yml`
- Create: `infra/ansible/roles/containerd/handlers/main.yml`
- Modify: `infra/ansible/playbooks/site.yml`

**Interfaces:**
- Consumes: OS prerequisites from the `common` role (Task 4).
- Produces: a running `containerd` service with `SystemdCgroup = true` on all 3 nodes — the container runtime the `kube-pkgs`/`kubeadm-init`/`kubeadm-join` roles (Tasks 6–8) rely on.

- [ ] **Step 1: Write the `containerd` role tasks**

`infra/ansible/roles/containerd/tasks/main.yml` (Amazon Linux 2023 ships `containerd` directly in its own dnf repos — no third-party repo needed):
```yaml
---
- name: Install containerd
  ansible.builtin.dnf:
    name: containerd
    state: present
    update_cache: true

- name: Create containerd config directory
  ansible.builtin.file:
    path: /etc/containerd
    state: directory
    mode: "0755"

- name: Generate default containerd config
  ansible.builtin.command: containerd config default
  register: containerd_default_config
  changed_when: false

- name: Write containerd config with SystemdCgroup enabled
  ansible.builtin.copy:
    dest: /etc/containerd/config.toml
    content: "{{ containerd_default_config.stdout | regex_replace('SystemdCgroup = false', 'SystemdCgroup = true') }}"
    mode: "0644"
  notify: Restart containerd

- name: Ensure containerd is enabled and running
  ansible.builtin.systemd:
    name: containerd
    enabled: true
    state: started
```

- [ ] **Step 2: Write the handler**

`infra/ansible/roles/containerd/handlers/main.yml`:
```yaml
---
- name: Restart containerd
  ansible.builtin.systemd:
    name: containerd
    state: restarted
```

- [ ] **Step 3: Add the role to the site playbook**

Modify `infra/ansible/playbooks/site.yml`:
```yaml
---
- name: Prepare all nodes
  hosts: all
  become: true
  roles:
    - common
    - containerd
```

- [ ] **Step 4: Run the playbook**

```bash
ansible-playbook playbooks/site.yml
```
Expected: 0 `failed`/`unreachable`.

- [ ] **Step 5: Verify containerd is active**

```bash
ansible all -m command -a "systemctl is-active containerd"
```
Expected: `active` on all 3 hosts.

- [ ] **Step 6: Commit**

```bash
git add infra/ansible/roles/containerd infra/ansible/playbooks/site.yml
git commit -m "infra(ansible): add containerd role

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 6: `kube-pkgs` role (kubelet/kubeadm/kubectl)

**Files:**
- Create: `infra/ansible/roles/kube-pkgs/tasks/main.yml`
- Modify: `infra/ansible/playbooks/site.yml`

**Interfaces:**
- Consumes: `kubernetes_minor_version` (Task 3); running `containerd` (Task 5).
- Produces: `kubeadm`, `kubelet`, `kubectl` installed on all 3 nodes, pinned to the `v1.31` package stream — required by `kubeadm-init` (Task 7) and `kubeadm-join` (Task 8).

- [ ] **Step 1: Write the role**

`infra/ansible/roles/kube-pkgs/tasks/main.yml` (dnf/rpm — the `pkgs.k8s.io` repo URL itself is pinned to the `v{{ kubernetes_minor_version }}` stream, so installing without an exact package version still only ever pulls 1.31.x builds):
```yaml
---
- name: Add the Kubernetes dnf repository
  ansible.builtin.yum_repository:
    name: kubernetes
    description: Kubernetes
    baseurl: "https://pkgs.k8s.io/core:/stable:/v{{ kubernetes_minor_version }}/rpm/"
    enabled: true
    gpgcheck: true
    gpgkey: "https://pkgs.k8s.io/core:/stable:/v{{ kubernetes_minor_version }}/rpm/repodata/repomd.xml.key"
    exclude: kubelet kubeadm kubectl cri-tools kubernetes-cni

- name: Install kubelet, kubeadm, kubectl
  ansible.builtin.dnf:
    name:
      - kubelet
      - kubeadm
      - kubectl
    state: present
    disable_excludes: kubernetes

- name: Prevent kubelet/kubeadm/kubectl from being upgraded by later dnf runs
  ansible.builtin.lineinfile:
    path: /etc/dnf/dnf.conf
    line: "exclude=kubelet kubeadm kubectl"
    create: true

- name: Ensure kubelet is enabled
  ansible.builtin.systemd:
    name: kubelet
    enabled: true
```

- [ ] **Step 2: Add the role to the site playbook**

Modify `infra/ansible/playbooks/site.yml`:
```yaml
---
- name: Prepare all nodes
  hosts: all
  become: true
  roles:
    - common
    - containerd
    - kube-pkgs
```

- [ ] **Step 3: Run the playbook**

```bash
ansible-playbook playbooks/site.yml
```
Expected: 0 `failed`/`unreachable`.

- [ ] **Step 4: Verify package versions and hold state**

```bash
ansible all -m command -a "kubeadm version -o short"
ansible all -m command -a "grep exclude /etc/dnf/dnf.conf"
```
Expected: a `v1.31.x` version from the first command on all 3 hosts; the second shows `exclude=kubelet kubeadm kubectl`.

- [ ] **Step 5: Commit**

```bash
git add infra/ansible/roles/kube-pkgs infra/ansible/playbooks/site.yml
git commit -m "infra(ansible): add kube-pkgs role for kubelet/kubeadm/kubectl

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 7: `kubeadm-init` + `calico` roles (control plane)

**Files:**
- Create: `infra/ansible/roles/kubeadm-init/tasks/main.yml`
- Create: `infra/ansible/roles/calico/tasks/main.yml`
- Modify: `infra/ansible/playbooks/site.yml`

**Interfaces:**
- Consumes: `control_plane_endpoint`, `pod_network_cidr`, `calico_version` (Task 3); `kubeadm` installed (Task 6).
- Produces: an initialized control plane on `kube-1`; `infra/ansible/fetched/kubeconfig` and `infra/ansible/fetched/join-command.sh` on the control machine, consumed by `kubeadm-join` (Task 8).

- [ ] **Step 1: Write the `kubeadm-init` role**

`infra/ansible/roles/kubeadm-init/tasks/main.yml`:
```yaml
---
- name: Check if the control plane is already initialized
  ansible.builtin.stat:
    path: /etc/kubernetes/admin.conf
  register: kubeadm_admin_conf

- name: Run kubeadm init
  ansible.builtin.command: >
    kubeadm init
    --control-plane-endpoint={{ control_plane_endpoint }}:6443
    --pod-network-cidr={{ pod_network_cidr }}
    --upload-certs
  when: not kubeadm_admin_conf.stat.exists

- name: Create .kube directory for the ansible_user
  ansible.builtin.file:
    path: "/home/{{ ansible_user }}/.kube"
    state: directory
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: "0755"

- name: Copy admin.conf into the user's kubeconfig
  ansible.builtin.copy:
    src: /etc/kubernetes/admin.conf
    dest: "/home/{{ ansible_user }}/.kube/config"
    remote_src: true
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: "0600"

- name: Fetch kubeconfig to the control machine
  ansible.builtin.fetch:
    src: /etc/kubernetes/admin.conf
    dest: "{{ playbook_dir }}/../fetched/kubeconfig"
    flat: true

- name: Generate a fresh kubeadm join command
  ansible.builtin.command: kubeadm token create --print-join-command
  register: kubeadm_join_command
  changed_when: false

- name: Save the join command on the control machine
  ansible.builtin.copy:
    content: "{{ kubeadm_join_command.stdout }}\n"
    dest: "{{ playbook_dir }}/../fetched/join-command.sh"
    mode: "0600"
  delegate_to: localhost
```

- [ ] **Step 2: Write the `calico` role**

`infra/ansible/roles/calico/tasks/main.yml`:
```yaml
---
- name: Download the Calico manifest
  ansible.builtin.get_url:
    url: "https://raw.githubusercontent.com/projectcalico/calico/{{ calico_version }}/manifests/calico.yaml"
    dest: /tmp/calico.yaml
    mode: "0644"

- name: Apply the Calico manifest
  ansible.builtin.command: kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /tmp/calico.yaml
  register: calico_apply
  changed_when: "'created' in calico_apply.stdout or 'configured' in calico_apply.stdout"
```

- [ ] **Step 3: Add a control-plane play to the site playbook**

Modify `infra/ansible/playbooks/site.yml`:
```yaml
---
- name: Prepare all nodes
  hosts: all
  become: true
  roles:
    - common
    - containerd
    - kube-pkgs

- name: Initialize the control plane
  hosts: control_plane
  become: true
  roles:
    - kubeadm-init
    - calico
```

- [ ] **Step 4: Run the playbook**

```bash
ansible-playbook playbooks/site.yml
```
Expected: 0 `failed`/`unreachable`; `infra/ansible/fetched/kubeconfig` and `infra/ansible/fetched/join-command.sh` now exist locally.

- [ ] **Step 5: Verify the control plane is Ready**

```bash
KUBECONFIG=infra/ansible/fetched/kubeconfig kubectl get nodes
KUBECONFIG=infra/ansible/fetched/kubeconfig kubectl get pods -n kube-system -l k8s-app=calico-node
```
Expected: `kube-1` shows `Ready`; Calico node pod shows `Running`/`1/1`.

- [ ] **Step 6: Commit**

```bash
git add infra/ansible/roles/kubeadm-init infra/ansible/roles/calico infra/ansible/playbooks/site.yml
git commit -m "infra(ansible): initialize kubeadm control plane and install Calico

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```
(`infra/ansible/fetched/` stays untracked — it's gitignored from Task 2.)

---

### Task 8: `kubeadm-join` role (workers)

**Files:**
- Create: `infra/ansible/roles/kubeadm-join/tasks/main.yml`
- Modify: `infra/ansible/playbooks/site.yml`

**Interfaces:**
- Consumes: `infra/ansible/fetched/join-command.sh` (Task 7); `kubeadm` installed on workers (Task 6).
- Produces: `kube-2` and `kube-3` joined to the cluster — final deliverable of this plan.

- [ ] **Step 1: Write the `kubeadm-join` role**

`infra/ansible/roles/kubeadm-join/tasks/main.yml`:
```yaml
---
- name: Check if this node already joined the cluster
  ansible.builtin.stat:
    path: /etc/kubernetes/kubelet.conf
  register: kubelet_conf

- name: Read the join command from the control machine
  ansible.builtin.slurp:
    src: "{{ playbook_dir }}/../fetched/join-command.sh"
  register: join_command_file
  delegate_to: localhost
  when: not kubelet_conf.stat.exists

- name: Run kubeadm join
  ansible.builtin.command: "{{ join_command_file.content | b64decode }}"
  when: not kubelet_conf.stat.exists
```

- [ ] **Step 2: Add a workers play to the site playbook**

Modify `infra/ansible/playbooks/site.yml`:
```yaml
---
- name: Prepare all nodes
  hosts: all
  become: true
  roles:
    - common
    - containerd
    - kube-pkgs

- name: Initialize the control plane
  hosts: control_plane
  become: true
  roles:
    - kubeadm-init
    - calico

- name: Join worker nodes
  hosts: workers
  become: true
  roles:
    - kubeadm-join
```

- [ ] **Step 3: Run the playbook**

```bash
ansible-playbook playbooks/site.yml
```
Expected: 0 `failed`/`unreachable`.

- [ ] **Step 4: Verify the full cluster is Ready**

```bash
KUBECONFIG=infra/ansible/fetched/kubeconfig kubectl get nodes -o wide
```
Expected: `kube-1`, `kube-2`, `kube-3` all `Ready`.

- [ ] **Step 5: Commit**

```bash
git add infra/ansible/roles/kubeadm-join infra/ansible/playbooks/site.yml
git commit -m "infra(ansible): join kube-2/kube-3 workers to the cluster

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 9: Idempotency verification & README

**Files:**
- Create: `infra/ansible/README.md`

**Interfaces:**
- Consumes: the full `site.yml` playbook (Tasks 4–8).
- Produces: documented proof of idempotence and a usage guide — closes out this sub-project.

- [ ] **Step 1: Re-run the full playbook against the live cluster**

```bash
ansible-playbook playbooks/site.yml
```
Expected: `PLAY RECAP` shows 0 `failed`/`unreachable`; tasks that mutate state only on first run (package installs, `kubeadm init`, `kubeadm join`, Calico apply) report `changed=0` or `skipped` this time — only inherently non-idempotent diagnostic tasks (e.g. `kubeadm token create`) are expected to show `changed`.

- [ ] **Step 2: Confirm the cluster is untouched**

```bash
KUBECONFIG=infra/ansible/fetched/kubeconfig kubectl get nodes
```
Expected: still 3 nodes `Ready`, same `AGE` progression as before (no pod restarts on kube-system triggered by the re-run).

- [ ] **Step 3: Write the README**

`infra/ansible/README.md`:
```markdown
# Infra bootstrap — Ansible

Provisions a 3-node kubeadm cluster (kube-1 control plane, kube-2/kube-3
workers) on the AWS VMs provided for the Kube project.

## Prerequisites

- AWS CLI v2 configured for SSO (`aws sso login`) with access to the group's
  EC2 instances and SSM.
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

## Known operational caveat

`kube-2`/`kube-3` have no stable public IP, so nothing external should target
them directly. Their private VPC IP is expected to remain stable across the
nightly shutdown/restart, but if the dynamic inventory (`inventory/aws_ec2.yml`)
ever returns a stale IP after a restart, re-run `ansible-inventory --graph` to
confirm the current addresses before re-running the playbook. A static
`inventory.ini` fallback can be substituted for the dynamic plugin if AWS API
access from the control machine becomes unavailable — see the spec at
`docs/superpowers/specs/2026-09-21-infra-bootstrap-design.md`.
```

- [ ] **Step 4: Commit**

```bash
git add infra/ansible/README.md
git commit -m "infra(ansible): document idempotency check and usage

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```
