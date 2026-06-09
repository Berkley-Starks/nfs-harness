# NFS Test Harness — Setup & Operations Guide

A from-scratch guide to what this project is, how it was set up, how to deploy /
validate / tear it down, and the real-world gotchas hit along the way. Pairs with
[CLAUDE.md](../CLAUDE.md) (architecture + principles) and the architecture diagram
in `NFS_Test_Harness_Architecture_PoC/Diagrams/`.

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

## 2. Prerequisites — what / why / how / where

| Tool | Why | How / where |
|---|---|---|
| **Terraform** ≥1.5 | Infrastructure layer (VPC, backend, fleet, guardrail) | Windows: `winget install Hashicorp.Terraform` (user scope). WSL: HashiCorp apt repo (see `bin/bootstrap-wsl.sh`). |
| **AWS CLI v2** | Credentials, identity, permission probing | Already present on the workstation; in WSL via `bin/bootstrap-wsl.sh`. |
| **WSL + Ansible** | Config layer (node_exporter, NFS mount, workload). Ansible has **no native Windows control node**, so it runs from WSL. | `wsl --install` (admin PowerShell + reboot), then `bash bin/bootstrap-wsl.sh`. |
| **jq** | Builds the Ansible inventory from `terraform output` | Installed by `bin/bootstrap-wsl.sh`. |
| **Docker** | NOT needed locally — the workload image is **built on each client node** by Ansible, so there's no registry and no local Docker dependency. | n/a |

Terraform runs fine on Windows for the whole infra path. Only the Ansible
`configure` step needs WSL.

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
   # Windows: lock perms -> icacls "%USERPROFILE%\.ssh\nfs-harness.pem" /inheritance:r /grant:r "%USERNAME%:(R)"
   ```
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

**Intended path (from the WSL control node — needs Ansible):**
```
./bin/harness up --clients 3     # backend + fleet + mount NFS + start workload
./bin/harness obs-up             # Prometheus/Grafana (reads scrape targets from the plane)
./bin/harness status             # Grafana URL + scrape targets
./bin/harness down               # destroy the test plane; instruments + network stay
./bin/harness obs-down           # park observability compute; metrics volume kept
```

**Raw terraform path (what was actually used to validate the infra on Windows):**
```
terraform -chdir=terraform apply -auto-approve
terraform -chdir=terraform output
terraform -chdir=terraform destroy -auto-approve
```

**What has been validated end-to-end:**
- Clean `terraform apply` → VPC, subnet, IGW, routes, 3 least-privilege SGs, EFS
  + mount target, 3 running client nodes, Lambda+EventBridge guardrail.
- **SSH** into a client with the key pair (proves Ansible connectivity; cloud-init
  ran; `python3` present).
- **Guardrail** invoked against the live fleet — correctly **kept** fresh
  instances (`kept: [...]`, `terminated: []`) and would terminate any older than
  `max_test_plane_age_hours` (default 3).
- Clean `terraform destroy` → 0 resources left (verified no VPC/EFS/role remain).

---

## 6. The IAM least-privilege journey (the real story)

tight is **condition-scoped on the `Project=nfs-harness` tag**, which makes
tag-on-create work but breaks for actions that authorize against a *parent*
resource or carry no request tags. The deploy surfaced these, in order:

| Finding | Resolution |
|---|---|
| `ec2:CreateKeyPair` denied | Use broad (one-time) — key pairs are setup, not per-cycle. |
| `ec2:ModifyVpcAttribute` denied (DNS-on-VPC) — **blocked the whole network** | Added to tight (ResourceTag). ✅ confirmed fixed. |
| `ec2:ModifySubnetAttribute` (auto-assign public IP) | Added to tight (ResourceTag). |
| `iam:GetRolePolicy` denied on **both** users (provider reads inline policy back) | Added to tight. ✅ confirmed fixed (guardrail policy now IaC-managed). Add to broad too. |
| `elasticfilesystem:ListTagsForResource` (EFS tag read-back) | Added to tight. |
| `iam:CreateServiceLinkedRole` for **spot** denied on both | Added (scoped to the Spot SLR) — or run on-demand. Workaround used: `client_capacity_type=on_demand`. |
| `RequestTag` condition blocks `AttachInternetGateway` / `CreateSubnet` / `CreateSecurityGroup` (they authorize on the VPC) | ✅ Fixed — moved EC2 build actions to an unconditioned statement; destructive actions stay ResourceTag-locked. |
| `ec2:CreateNetworkInterface` denied (EFS `CreateMountTarget` places an ENI as the caller) | ✅ Fixed — added ENI create/delete/modify to the build statement. |

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
  On-demand `t3.small` ×3 ≈ $0.06/hr; flip to spot for 70–90% off once the Spot
  SLR exists.

---

## 8. Status — done vs remaining

**Done:**
- Full build of all layers; `terraform validate`/`fmt` clean; bash + Lambda
  syntax-checked.
- Live deploy validated end-to-end (apply → fleet + EFS + guardrail → SSH →
  guardrail invoke → clean destroy).
- IAM gaps characterized; corrected tight policy drafted.

**Remaining:**
1. ~~Finalize the tight policy~~ — done; full apply+destroy validated on tight.
2. `wsl --install` + `bin/bootstrap-wsl.sh` to enable the Ansible `configure` step.
3. `obs-up` + `./bin/harness configure` → confirm **live NFS metrics in Grafana**
   (node_exporter `mountstats` on the fleet → Prometheus → Grafana dashboard).
4. Optional: create the EC2 Spot service-linked role, flip clients back to spot.

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
