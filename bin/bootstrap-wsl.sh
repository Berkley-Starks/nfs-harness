#!/usr/bin/env bash
###############################################################################
# bootstrap-wsl.sh — provision a WSL (Ubuntu) control node for the harness.
#
# Installs terraform, ansible, awscli, jq and the ansible.posix collection, then
# points AWS at your existing Windows credentials so the `nfs-harness` profile
# you configured on Windows works unchanged inside WSL.
#
# Run once, inside WSL:   bash bin/bootstrap-wsl.sh
###############################################################################
set -euo pipefail

say() { echo "==> $*"; }

say "apt prerequisites"
sudo apt-get update -y
sudo apt-get install -y software-properties-common gnupg lsb-release jq unzip curl python3-pip

# --- terraform (HashiCorp apt repo) --------------------------------------
if ! command -v terraform >/dev/null 2>&1; then
  say "installing terraform"
  wget -qO- https://apt.releases.hashicorp.com/gpg | \
    sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  sudo apt-get update -y && sudo apt-get install -y terraform
fi

# --- ansible --------------------------------------------------------------
if ! command -v ansible-playbook >/dev/null 2>&1; then
  say "installing ansible"
  sudo apt-get install -y ansible
fi
say "installing ansible collections"
ansible-galaxy collection install -r "$(dirname "$0")/../ansible/requirements.yml"

# --- aws cli v2 -----------------------------------------------------------
if ! command -v aws >/dev/null 2>&1; then
  say "installing aws cli v2"
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  (cd /tmp && unzip -q awscliv2.zip && sudo ./aws/install)
fi

# --- share Windows AWS creds into WSL -------------------------------------
# Find the Windows user dir that has a .aws/credentials and reuse it directly.
WIN_AWS=""
for d in /mnt/c/Users/*/.aws; do
  [ -f "$d/credentials" ] && WIN_AWS="$d" && break
done

if [ -n "$WIN_AWS" ]; then
  say "wiring AWS creds from $WIN_AWS"
  if ! grep -q "AWS_SHARED_CREDENTIALS_FILE" "$HOME/.bashrc"; then
    {
      echo ""
      echo "# nfs-harness: reuse Windows AWS profiles inside WSL"
      echo "export AWS_SHARED_CREDENTIALS_FILE=\"$WIN_AWS/credentials\""
      echo "export AWS_CONFIG_FILE=\"$WIN_AWS/config\""
    } >> "$HOME/.bashrc"
  fi
  export AWS_SHARED_CREDENTIALS_FILE="$WIN_AWS/credentials"
  export AWS_CONFIG_FILE="$WIN_AWS/config"
else
  say "no Windows .aws found — run 'aws configure --profile nfs-harness' in WSL"
fi

say "versions:"
terraform version | head -1
ansible --version | head -1
aws --version
jq --version

say "done. Open a new shell (or 'source ~/.bashrc'), then:"
say "  aws sts get-caller-identity --profile nfs-harness-tight"
