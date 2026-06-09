# `nfs-harness-tight` — permission gap ledger

Living record of where the least-privilege user (`nfs-harness-tight`) fails, so
the granular policy can be built out deliberately over time. Flip
`aws_profile = "nfs-harness-broad"` to unblock; then add the statement here and
tighten tight.

**Account:** 111122223333 · **Region:** us-east-1
**Method:** EC2 `--dry-run` probes (auth-only) + real read calls + apply observations.

## ✅ VALIDATED 2026-06-09

With the corrected policy
([iam/nfs-harness-tight-policy.json](iam/nfs-harness-tight-policy.json)) applied to
`nfs-harness-tight`, the **full lifecycle runs end-to-end on tight alone** — no
broad fallback, no `-refresh=false`, no out-of-band steps:
- `terraform apply` → **EXIT 0** (VPC, subnet, IGW+attach, 3 SGs, 3 instances,
  EFS + mount target, guardrail with IaC-managed inline policy).
- `terraform destroy` → **EXIT 0**, verified no VPC/EFS/instances remain.

(on-demand clients; spot still needs the EC2-Spot SLR — gap #5.) Remaining
finding #7's `RequestTag` restructure and #8's `CreateNetworkInterface` are both
incorporated and confirmed working.

## RESOLUTION — corrected tight policy

A ready-to-paste, gap-closed policy lives at
[docs/iam/nfs-harness-tight-policy.json](iam/nfs-harness-tight-policy.json). It is
the user's policy plus these additions:

| Added action | Statement | Closes |
|---|---|---|
| `ec2:ModifyVpcAttribute` | VisualEditor1 (ResourceTag) | gap #1 — DNS-on-VPC (THE blocker) |
| `ec2:ModifySubnetAttribute` | VisualEditor1 (ResourceTag) | map_public_ip_on_launch (next blocker) |
| `iam:GetRolePolicy` | VisualEditor5 (read) | gap #2 — inline-policy read-back (also missing on broad) |
| `elasticfilesystem:ListTagsForResource` | VisualEditor5 (read) | EFS tag read-back (Describe* doesn't cover it) |
| `iam:CreateServiceLinkedRole` (spot only) | VisualEditor6 (new) | gap #5 — lets tight create the EC2-Spot SLR |

After applying it, flip `manage_guardrail_inline_policy=true` and `terraform
import aws_iam_role_policy.teardown[0] nfs-harness-teardown:nfs-harness-teardown`
to put the guardrail policy back under IaC. Add `iam:GetRolePolicy` to **broad**
too (it lacks it as well).

## How tight is scoped (confirmed)

EC2 **create** actions are conditioned on the `Project=nfs-harness` tag:
untagged `CreateVpc` → DENY, tagged `CreateVpc` → ALLOW. Terraform applies
`default_tags` on create, so tag-on-create resources satisfy that. The gaps
below are mostly **non-create** verbs (Modify*, Get*) that carry no RequestTag
and so aren't covered by the tag-conditioned create grants.

## Confirmed ALLOW

| Action | Evidence |
|---|---|
| `ec2:CreateVpc` (tagged) | dry-run + real (vpc created) |
| `ec2:CreateLaunchTemplate` (tagged) | dry-run ALLOW |
| `ec2:DescribeImages` / `DescribeAvailabilityZones` | plan resolves |
| `elasticfilesystem:CreateFileSystem` | **real: fs-0af25b9de69eb21a9 created** |
| `iam:CreateRole` | **real: role nfs-harness-teardown created** |
| `iam:PutRolePolicy` | real (Put succeeded; only the Get read-back failed) |
| `lambda:CreateFunction` | **real: function nfs-harness-teardown created** |
| `lambda:AddPermission` | real (permission created) |
| `events:PutRule` / `events:PutTargets` | **real (rule + target created)** |
| `efs/lambda/events` describe/list | read ALLOW |

## GAPS (tight DENY)

### 1. `ec2:ModifyVpcAttribute` — DENY  ⛔ BLOCKING
- **When:** apply 2026-06-08. `CreateVpc` succeeded (vpc-0f9736f698467b711) but
  the provider's follow-up `ModifyVpcAttribute` (enable DNS hostnames/support,
  from `enable_dns_hostnames=true` in network.tf) was denied — halting the whole
  network build (subnet/IGW/RT/SG never ran; `RunInstances` never reached).
- **Fix:**
  ```json
  { "Sid": "VpcAttrs", "Effect": "Allow",
    "Action": ["ec2:ModifyVpcAttribute"],
    "Resource": "arn:aws:ec2:us-east-1:111122223333:vpc/*",
    "Condition": {"StringEquals": {"aws:ResourceTag/Project": "nfs-harness"}} }
  ```
  (DNS-on-VPC is set during create; the action has no RequestTag, so condition on
  ResourceTag. If still denied, drop the condition — ModifyVpcAttribute has weak
  condition-key support.)

### 2. `iam:GetRolePolicy` — DENY on BOTH tight AND broad ⚠️
- **When:** tight apply (read-back after PutRolePolicy) AND the broad re-apply
  (refresh phase: "reading inline policies for IAM role nfs-harness-teardown").
  Terraform reads back every inline role policy, so this blocks ANY apply/destroy
  that has `aws_iam_role_policy.teardown` in state — on both users.
- **Workaround used:** `terraform apply -refresh=false` to skip the read-back and
  build the rest of the fleet. Proper fix = add the statement below to the
  profile you deploy with (broad now; tight as you harden).
- **Fix (round out IAM read for the role lifecycle):**
  ```json
  { "Sid": "TeardownRoleRead", "Effect": "Allow",
    "Action": ["iam:GetRole","iam:GetRolePolicy","iam:ListRolePolicies",
               "iam:ListAttachedRolePolicies","iam:DeleteRolePolicy","iam:DeleteRole","iam:PassRole","iam:TagRole"],
    "Resource": "arn:aws:iam::111122223333:role/nfs-harness-*" }
  ```

### 3. `ec2:CreateKeyPair` — DENY
- **When:** creating the `nfs-harness` key pair. broad created it instead.
- **Fix:** `ec2:CreateKeyPair` + `ec2:DescribeKeyPairs` (cond. RequestTag Project),
  or just leave key-pair creation on broad (one-time).

### 4. `ec2:RunInstances` — ALLOWED (resolved)
- Launch into the real tagged subnet got far enough to attempt the spot
  service-linked-role creation, i.e. the `RunInstances` action itself is
  permitted. The earlier untagged dry-run DENY was a false negative (default-VPC
  context). No action needed for RunInstances.

### 5. `iam:CreateServiceLinkedRole` (spot) — DENY on BOTH ⛔
- **When:** broad re-apply. Spot launch returned
  `AuthFailure.ServiceLinkedRoleCreationNotPermitted` — the account's
  `AWSServiceRoleForEC2Spot` role doesn't exist and neither profile can create it.
- **Fixes (pick one):**
  - One-time, by an admin/IAM principal:
    `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com`
    (then both `*_capacity_type = "spot"` work).
  - Or grant the deploy user `iam:CreateServiceLinkedRole` scoped to
    `arn:aws:iam::*:role/aws-service-role/spot.amazonaws.com/*`.
  - **Workaround in use:** `client_capacity_type = "on_demand"` (no SLR needed).
- **Status:** open — spot disabled until the SLR exists; on-demand for now.

### 6. `aws_iam_role_policy.teardown` removed from TF state (workaround)
- Because neither profile has `iam:GetRolePolicy`, that resource was stuck
  tainted and blocked every apply. Ran `terraform state rm
  aws_iam_role_policy.teardown`. The inline policy still EXISTS on the role
  (PutRolePolicy succeeded on the first tight apply), so the guardrail works;
  terraform just no longer manages that one resource. Grant `iam:GetRolePolicy`
  (gap #2) then `terraform import` it back to restore full IaC management.

### 7. `RequestTag` condition blocks parent-resource / attach actions ⛔
- **When:** validation apply on the UPDATED tight policy (2026-06-09). Confirmed
  fixed: `ec2:ModifyVpcAttribute` (VPC completed) and `iam:GetRolePolicy` (guardrail
  inline policy now created + read back under IaC). But new denials:
  `ec2:AttachInternetGateway`, `ec2:CreateSubnet`, `ec2:CreateSecurityGroup` — all
  "on resource .../vpc/...".
- **Root cause:** these actions authorize against the **parent VPC** (or, for
  AttachInternetGateway, carry no tags at all). An `aws:RequestTag/Project`
  condition can never match the VPC-resource leg / a no-tag request, so gating
  them on RequestTag (as VisualEditor0 does) denies them.
- **Fix (pragmatic, works):** move the EC2 build actions in VisualEditor0 to a
  statement with `Resource: "*"` and **no tag condition**. Tightness is preserved
  by VisualEditor1 (destructive actions stay `aws:ResourceTag/Project`-locked) and
  the ARN-scoped IAM/Lambda/Events statement. Same applies to EFS mount-target
  actions (mount targets can't be tagged) — leave EFS unconditioned.
- **Fix (tightest, verbose):** per action, dual statements — RequestTag on the
  new-resource ARN, plus an allow on the parent `vpc/*` ARN (ResourceTag) — the
  AWS-documented tag-on-create pattern.
- **Status:** open — next policy revision.

### 8. `ec2:CreateNetworkInterface` — DENY (EFS mount target) ⛔
- **When:** apply on the #7-fixed policy (2026-06-09). Everything else succeeded on
  tight — VPC+ModifyVpcAttribute, AttachInternetGateway, CreateSubnet,
  CreateSecurityGroup, RunInstances (×3), guardrail (IaC-managed). Only
  `elasticfilesystem:CreateMountTarget` failed: `AccessDeniedException`.
- **Root cause:** CreateMountTarget makes the EFS service place an **ENI** in your
  subnet **using the caller's credentials**, so the caller needs
  `ec2:CreateNetworkInterface` (confirmed denied via dry-run). Teardown
  (DeleteMountTarget) needs `ec2:DeleteNetworkInterface`.
- **Fix:** added `ec2:CreateNetworkInterface`, `ec2:DeleteNetworkInterface`,
  `ec2:ModifyNetworkInterfaceAttribute` to the unconditioned EC2 build statement
  (the mount-target ENI is EFS-managed/untagged, so it can't be tag-gated).
- **Status:** fix in the policy file; pending the next apply to confirm.

## Still UNKNOWN (resolve on next apply)

- `ec2:CreateSubnet/InternetGateway/RouteTable/Route/AssociateRouteTable/CreateSecurityGroup/AuthorizeSecurityGroup*`
  — expected ALLOW tagged; not reached (blocked by #1).
- `elasticfilesystem:CreateMountTarget` — fs created; mount target not reached.
- `ec2:RunInstances` + `ec2:CreateTags` on launch — see #4.

_Last updated: 2026-06-08 (after first tight apply — failed at ModifyVpcAttribute)._
