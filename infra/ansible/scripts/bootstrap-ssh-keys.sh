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
