# NFS Test Harness — Setup & Operations Guide

A from-scratch guide to what this project is, how it was set up, how to deploy /
validate / tear it down, and the real-world gotchas hit along the way. Pairs with
the architecture diagram in [docs/diagrams/](diagrams/nfs_test_harness_architecture.svg).

---

## 1. What this is

An **ephemeral, cost-bounded NFS test harness on AWS**. It stands up an NFS
backend (EFS or a self-managed server) plus a fleet of NFS client nodes, drives a
containerized `fio` workload against the share, watches it from an independent
observability plane (Prometheus/Grafana), and tears the test plane down between
runs. Two-plane split is the core idea: the **test plane** is disposable; the
**observability plane** survives so your instruments never die with the system
under test.

---

## 2. Prerequisites — the control node

You drive the harness from a **control node** that needs four tools:

| Tool | Why |
|---|---|
| **Terraform** ≥1.5 | Infrastructure layer (VPC, backend, fleet, guardrail) |
| **Ansible** | Config layer (node_exporter, NFS mount, workload) |
| **AWS CLI v2** | Credentials, identity, permission probing |
| **jq** | Builds the Ansible inventory from `terraform output` |

Docker is **not** needed locally — the workload image is built on each client node
by Ansible, so there's no registry or local Docker dependency.

Ansible runs natively on **macOS** and **Linux**. On **Windows** it has no native
control node, so you run from **WSL (Ubuntu)** — install WSL once
(`wsl --install` in an admin PowerShell, then reboot) and treat it as a Linux box.

### Install (pick your OS)

**macOS (Homebrew):**
```bash
brew install terraform ansible awscli jq
```

**Linux — Debian/Ubuntu:**
```bash
# Terraform from the HashiCorp apt repo:
wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform ansible jq unzip
# AWS CLI v2:
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
(cd /tmp && unzip -q awscliv2.zip && sudo ./aws/install)
```
*(Fedora/RHEL: use `dnf` + the HashiCorp `yum` repo. Arch: `pacman -S terraform ansible aws-cli jq`.)*

**Windows (WSL/Ubuntu):** the bundled script does the Debian steps above **and**
wires your Windows AWS credentials into WSL:
```bash
wsl --install            # admin PowerShell, then reboot
bash bin/bootstrap-wsl.sh
```

**All platforms** — install the one Ansible collection the playbook needs, then verify:
```bash
ansible-galaxy collection install -r ansible/requirements.yml
terraform version && ansible --version && aws --version && jq --version
```

---

## 3. AWS account & the tight/broad IAM model

- **Account:** `111122223333` · **Region:** `us-east-1`
- Two deploy users, by design:
  - **`nfs-harness-tight`** — least-privilege, granular, condition-scoped. The
    default (`aws_profile` in tfvars). The goal is for normal `up`/`down` cycles
    to run on this.
  - **`nfs-harness-broad`** — permissive escape hatch. When a tight policy is
    missing an action and blocks an apply, flip `aws_profile` to broad to unblock,
    then add the missing statement to tight and tighten back.
- The full record of where tight (and sometimes broad) fell short, with the exact
  IAM statements to close each gap, lives in
  [tight-iam-gaps.md](tight-iam-gaps.md). A ready-to-paste corrected tight policy
  is at [iam/nfs-harness-tight-policy.json](iam/nfs-harness-tight-policy.json).

---

## 4. First-time setup (step by step)

1. **Configure both profiles** (in your own terminal — never paste secret keys
   into a shared session):
   ```
   aws configure --profile nfs-harness-tight
   aws configure --profile nfs-harness-broad
   aws sts get-caller-identity --profile nfs-harness-tight   # verify
   ```
2. **Create the EC2 key pair** (one-time; `CreateKeyPair` is not on tight, so use
   broad or the console):
   ```
   aws ec2 create-key-pair --profile nfs-harness-broad --region us-east-1 \
     --key-name nfs-harness \
     --tag-specifications 'ResourceType=key-pair,Tags=[{Key=Project,Value=nfs-harness}]' \
     --query KeyMaterial --output text > ~/.ssh/nfs-harness.pem
   chmod 600 ~/.ssh/nfs-harness.pem   # macOS / Linux / WSL
   ```
   WSL note: keep the key in your **WSL home** (`~/.ssh/`), not on `/mnt/c/...` —
   the Windows mount is world-writable (`0777`) and SSH/Ansible reject the key. If
   you created it on Windows, copy it in:
   `cp /mnt/c/Users/<you>/.ssh/nfs-harness.pem ~/.ssh/ && chmod 600 ~/.ssh/nfs-harness.pem`.
3. **Set tfvars:**
   ```
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   # set ssh_key_name = "nfs-harness"
   # set admin_cidr   = "<your-ip>/32"   (curl -s https://checkip.amazonaws.com)
   cp terraform/observability/terraform.tfvars.example terraform/observability/terraform.tfvars
   ```
4. **Init + validate:**
   ```
   terraform -chdir=terraform init
   terraform -chdir=terraform validate
   ```

---

## 5. Deploy / validate / tear down

**Intended path (from the control node — macOS / Linux / WSL):**
```
./bin/harness up --clients 3     # EFS (default), 3 clients, mount NFS + start workload
./bin/harness obs-up             # Prometheus/Grafana (reads scrape targets from the plane)
./bin/harness status             # Grafana URL + scrape targets
./bin/harness down               # destroy the test plane; instruments + network stay
./bin/harness obs-down           # park observability compute; metrics volume kept
```

Per-run knobs are **flags** (no tfvars edits; `--flag value` or `--flag=value`):
```
./bin/harness up --nfs=self_managed --clients=20 --cluster-clients  # self-managed + 20 co-located clients
./bin/harness up --nfs=efs --instance=t3.small --clients=5          # cheap smoke test (burstable clients)
./bin/harness up                                          # defaults: efs, c5n.large clients, spot, 3 clients
```
Unset flags fall back to terraform defaults (`efs` backend / `c5n.large` clients /
`m5dn.large` self-managed server / `spot` / 3 clients). The client/server defaults
are network-optimized for benchmark correctness — pass `--instance t3.small` for a
cheap smoke test. After changing the fleet, re-run `obs-up` so Prometheus picks up
the new targets.

**Raw terraform path (infra only, any OS — skips the Ansible config step):**
```
terraform -chdir=terraform apply -auto-approve
terraform -chdir=terraform output
terraform -chdir=terraform destroy -auto-approve
```

**What has been validated end-to-end (against live AWS):**
- Full `apply` **and** `destroy` on the least-privilege `tight` profile alone —
  EXIT 0 both, no broad fallback.
- **Both backends:** EFS and a self-managed NFS server, switched with `--nfs`.
- **Fleet scaled 3 → 10 → 20 clients** via `--clients`, all configured by Ansible
  (`failed=0` across every host).
- **Live Grafana dashboard** of real `fio` NFS load — fleet ops/s, throughput, and
  (on self-managed) the single server saturating as the visible bottleneck.
- **Observability survives test-plane teardown;** the persistent metrics EBS
  re-attaches across obs-box rebuilds, retaining history from earlier runs.
- **Guardrail** reaps stale `TestPlane` instances past its TTL (configurable via
  `max_test_plane_age_hours`; bumped to 16h for an overnight run).

---

## 6. The IAM least-privilege journey (the real story)

tight is **condition-scoped on the `Project=nfs-harness` tag**, which makes
tag-on-create work but breaks for actions that authorize against a *parent*
resource or carry no request tags. The deploy surfaced these, in order:

| Finding | Resolution |
|---|---|
| `ec2:CreateKeyPair` denied | Use broad (one-time) — key pairs are setup, not per-cycle. |
| `ec2:ModifyVpcAttribute` denied (DNS-on-VPC) — **blocked the whole network** | Added to tight (ResourceTag). confirmed fixed. |
| `ec2:ModifySubnetAttribute` (auto-assign public IP) | Added to tight (ResourceTag). |
| `iam:GetRolePolicy` denied on **both** users (provider reads inline policy back) | Added to tight. confirmed fixed (guardrail policy now IaC-managed). Add to broad too. |
| `elasticfilesystem:ListTagsForResource` (EFS tag read-back) | Added to tight. |
| `iam:CreateServiceLinkedRole` for **spot** denied on both | Added (scoped to the Spot SLR) — or run on-demand. Workaround used: `client_capacity_type=on_demand`. |
| `RequestTag` condition blocks `AttachInternetGateway` / `CreateSubnet` / `CreateSecurityGroup` (they authorize on the VPC) | Fixed — moved EC2 build actions to an unconditioned statement; destructive actions stay ResourceTag-locked. |
| `ec2:CreateNetworkInterface` denied (EFS `CreateMountTarget` places an ENI as the caller) | Fixed — added ENI create/delete/modify to the build statement. |

**Result:** with the corrected policy, the **entire lifecycle (`apply` + `destroy`)
runs on `nfs-harness-tight` alone** — no broad fallback, no `-refresh=false`, no
out-of-band steps. Validated 2026-06-09.

**Workarounds used during bring-up** (all documented in the gap ledger):
- Flip `aws_profile` to broad to get past tight gaps.
- `terraform apply -refresh=false` to skip the inline-policy read-back while
  neither user had `iam:GetRolePolicy`.
- `bin/apply-guardrail-policy.sh` to attach the guardrail's inline policy
  out-of-band (`PutRolePolicy` works; only the read-back didn't), with
  `manage_guardrail_inline_policy=false` so terraform didn't try to track it.
- **Note:** IAM changes are eventually consistent — a freshly updated role policy
  took ~1–2 minutes to propagate to the Lambda/STS plane.

---

## 7. Lifecycle & cost model

- **Test plane** = disposable. `harness down` flips `test_plane_enabled=false` and
  applies — destroying NFS backend + fleet while VPC, SGs, and the guardrail
  persist. No `-target` anti-pattern.
- **Observability** = separate Terraform state. `harness down` can't reach it.
  `obs-down` flips `observability_running=false` → EC2 gone, the **persistent
  metrics EBS** (`prevent_destroy`, no `TestPlane` tag) stays.
- **Guardrail** = serverless cost backstop. EventBridge → Lambda terminates any
  `TestPlane=true` instance older than N hours, scoped by IAM to this project's
  tag only. Catches a forgotten `down`.
- **Idle cost** ≈ one small EBS volume (only if observability metrics exist).
  The benchmark default (5× `c5n.large` + `m5dn.large`, all spot) ≈ a few $/hr
  on-demand and 70–90% less on spot; a cheap smoke test (`--instance t3.small` ×3,
  EFS) ≈ $0.06–0.12/hr. Spot needs the EC2-Spot SLR (created once).

---

## 8. Status — done vs remaining

**Done:**
- All layers built; `terraform validate`/`fmt` clean; bash + Lambda syntax-checked.
- Validated end-to-end on live AWS (see section 5): full apply+destroy on the
  `tight` profile, both EFS and self-managed backends, fleet scaled to 20 clients,
  live NFS metrics in Grafana, guardrail proven.
- Per-run flags (`--nfs`, `--instance`, `--clients`, `--capacity`) so a run never
  needs a code/tfvars edit.
- IAM least-privilege policy characterized and validated end-to-end (see
  [tight-iam-gaps.md](tight-iam-gaps.md)).

**Remaining / roadmap** (tracked in the README TODO):
1. Mixed-backend comparison runs — EFS and self-managed in a single run with
   independent per-backend client counts.
2. Self-managed server scale — `--servers N` and per-pool instance types.
3. Per-run guardrail TTL flag (`--ttl`) instead of a tfvars edit.
4. Optional: create the EC2-Spot service-linked role so the fleet can run on spot
   (70–90% cheaper than on-demand).

---

## 9. Troubleshooting quick reference

| Symptom | Cause / fix |
|---|---|
| `UnauthorizedOperation: ec2:ModifyVpcAttribute` | tight missing it; added (ResourceTag). Network build halts without it. |
| `ec2:ModifySubnetAttribute` denied | Needed for `map_public_ip_on_launch`. Add to tight. |
| `GetRolePolicy ... AccessDenied` on apply/destroy | Deploy principal lacks `iam:GetRolePolicy`. Add it (both users), or `-refresh=false` + `manage_guardrail_inline_policy=false` as a stopgap. |
| `AuthFailure.ServiceLinkedRoleCreationNotPermitted` (spot) | No EC2-Spot SLR + no `iam:CreateServiceLinkedRole`. Create the SLR once, or use `client_capacity_type=on_demand`. |
| `CreateSubnet`/`CreateSecurityGroup`/`AttachInternetGateway` denied "on resource vpc-..." | `RequestTag` condition can't match parent-resource actions. Move those creates to an unconditioned statement. |
| Lambda guardrail: `UnauthorizedOperation` right after a policy change | IAM propagation lag — wait 1–2 min and re-invoke. |
| `InvalidKeyPair.NotFound` at `RunInstances` | The key named by `ssh_key_name` doesn't exist in the region. Create it (step 4.2). |
| (WSL) "ignoring world-writable ansible.cfg", then "no hosts matched" | The `/mnt/c` mount is `0777`, so Ansible drops `ansible.cfg` and loses the inventory. The `harness` wrapper sets `ANSIBLE_CONFIG` + `-i` explicitly to avoid this; if you invoke `ansible-playbook` by hand, do the same (or run from a path outside `/mnt/c`). |
| (newer Ansible) "yaml callback plugin has been removed" | `ansible-core` ≥2.13 dropped the `yaml` stdout callback; the bundled `ansible.cfg` uses `result_format = yaml` instead. Update yours if you copied an old one. |
