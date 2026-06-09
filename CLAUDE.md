# NFS Test Harness — Project Context for Claude Code

This file orients any Claude Code session picking up this project. Read it first.

## What this project is

An **ephemeral, cost-bounded NFS test harness in AWS**, built as interview-prep
artifact AND a genuinely useful tool. It stands up an NFS backend + a fleet of
NFS client nodes, hammers the backend with a containerized workload, monitors
everything from a separate observability plane, and tears the whole test plane
down between runs. Models the literal day-one task described in the interview:
"stand up NFS clients at scale in AWS, run repro/test code, monitor it, automate
spin-up/tear-down for ~2-hour test cycles."

## Architectural principles (do not violate these)

1. **Two-plane split.** The *test plane* (NFS server + client fleet) is
   disposable and destroyed every cycle. The *observability/control plane*
   (Prometheus/Grafana + the harness wrapper) has an INDEPENDENT lifecycle and
   SURVIVES test-plane destruction. Rationale: your debugging instruments must
   never die with the system under test.

2. **Observability compute is on-demand; observability STORAGE persists.** The
   Prometheus EC2 instance is created for a run and torn down when idle, but its
   metrics live on a separate EBS volume (own resource, `prevent_destroy`) that
   re-attaches. Only continuous cost is that cheap EBS volume.

3. **Spot by default, independently flippable.** Both NFS server and client
   fleet default to spot (`*_capacity_type` vars). Clients are textbook spot
   (cattle, interruption-tolerant, 70-90% cheaper). The server is more pet:
   spot is fine for repro/load tests, flip to on_demand for clean uninterrupted
   benchmark runs. The two are independent on purpose.

4. **Selectable NFS backend.** `nfs_backend` var = "efs" or "self_managed".
   EFS proves the harness fast (managed, serverless). self_managed gives a real
   server you can break/instrument (and later: the actual Hammerspace product).
   The EFS-vs-self-managed tradeoff is a runtime toggle, not a fork.

5. **Least-privilege security groups.** Intra-harness rules reference other SGs
   by id, not CIDR. NFS:2049 only from client SG. node_exporter:9100 only from
   observability SG. SSH only from admin_cidr (never 0.0.0.0/0).

6. **Layer ownership.** Terraform = infrastructure. Ansible = config (install
   container runtime, mount NFS, launch workload container). Container = the
   workload itself. Keep these layers clean.

## Serverless decisions (already reasoned through)

- Clients/server: EC2 (long-lived, stateful, mounted, ARE the system under
  test). NOT Lambda (15-min cap, stateless) — Lambda would mask the very layer
  being tested.
- EFS backend = serverless storage (legit win).
- Lambda + EventBridge = the real serverless win: auto-teardown guardrail
  (destroy any test plane older than N hours) + start/stop observability. NOT
  YET BUILT — planned.
- Fargate considered for clients; rejected for now (less kernel/NFS-client
  control, which is what we're testing; pricier than spot). Know the tradeoff.

## Build status — FULL BUILD COMPLETE (validated 2026-06-08)

All layers built and `terraform validate`/`fmt` clean against AWS provider
v5.100.0 (terraform 1.15.5). Bash + Lambda syntax-checked. NOT yet deployed to
AWS — see "Remaining to deploy" below.

terraform/ (test plane + guardrail, one root/state):
- providers.tf      — AWS + archive providers, profile, default tags, S3 backend upgrade path (commented)
- variables.tf      — all vars w/ validation; test_plane_enabled master switch; capacity-type vars; nfs_backend selector; client_count; guardrail vars
- network.tf        — VPC, subnet, IGW, route table, 3 least-privilege SGs + 9100 scrape rules + 9090 admin
- data.tf           — shared ungated AL2023 AMI lookup (clients need it for any backend)
- nfs_backend.tf    — selectable EFS or self-managed server, both gated on test_plane_enabled; server spot via dynamic instance_market_options
- clients.tf        — client fleet: launch template (spot/on-demand) + count, TestPlane/Role tags, minimal user-data (config is Ansible's job)
- teardown.tf       — Lambda + EventBridge guardrail; IAM scoped to TerminateInstances on Project-tagged only; archive_file zips the handler
- outputs.tf        — nfs_endpoint resolves regardless of backend; fleet IPs + subnet_az for the obs root + inventory
- terraform.tfvars.example

terraform/observability/ (SEPARATE root/state — independent lifecycle):
- providers.tf      — own provider; terraform_remote_state reads ../terraform.tfstate for network + scrape targets
- main.tf           — persistent gp3 EBS (prevent_destroy, no TestPlane tag) + on-demand Prometheus/Grafana EC2 gated on observability_running + volume attachment
- templates/cloud-init.sh.tftpl — re-attach-safe EBS mount, docker, Prometheus + Grafana (provisioned datasource + starter NFS dashboard)
- variables.tf / outputs.tf / terraform.tfvars.example

ansible/ (config layer, runs from WSL):
- site.yml          — play1 node_exporter on all hosts; play2 nfs_client + workload on clients
- roles/node_exporter — binary + systemd unit, mountstats+nfs collectors (NFS client metrics)
- roles/nfs_client    — nfs-utils + mount resolved endpoint (nfs4 for EFS, nfs for self-managed)
- roles/workload      — docker + build/run the workload container against the mount (shells out to docker CLI; no python SDK on nodes)
- requirements.yml (ansible.posix), ansible.cfg, inventory/ (hosts.ini generated by bin/harness)

workload/ — Alpine + fio load generator (Dockerfile + run-load.sh, env-tunable, per-host subdirs, loops for the test window)

bin/ — harness (up/configure/down/obs-up/obs-down/status/plan/destroy-all) + bootstrap-wsl.sh (provisions the WSL control node, wires Windows AWS creds)

## Lifecycle model (how the two planes stay independent)

- Test plane and guardrail live in terraform/. `harness down` = flip
  `test_plane_enabled=false` and apply → NFS backend + fleet destroyed; VPC, SGs,
  and the guardrail persist. No -target anti-pattern.
- Observability is a SEPARATE root/state. `harness down` cannot reach it.
  `obs-down` flips `observability_running=false` → EC2 gone, EBS (with every
  metric) stays. The network it sits in is owned by the test-plane root and is
  treated as persistent shared substrate (a named simplification: the VPC is not
  part of the disposable "NFS server + client fleet").

## Run sequence (from the WSL control node)

bash bin/bootstrap-wsl.sh                      # once: terraform/ansible/aws/jq + creds
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # set ssh_key_name, admin_cidr
cp terraform/observability/terraform.tfvars.example terraform/observability/terraform.tfvars
./bin/harness up --clients 3                   # backend + fleet + mount + workload (creates the VPC too)
./bin/harness obs-up                           # instruments (read the test-plane state for scrape targets)
./bin/harness status                           # Grafana URL, scrape targets
# ...watch load land in Grafana...
./bin/harness down                             # destroy SUT; VPC + instruments + metrics stay
./bin/harness obs-down                         # park obs compute; metrics volume kept
# Note: obs-up needs the test-plane state to exist (it reads the VPC/subnet/SG +
# scrape targets via terraform_remote_state). The network persists across `down`,
# so on later cycles obs genuinely survives — only the first bring-up is ordered.

## Remaining to deploy (not code — environment)
1. AWS profiles `nfs-harness-tight` (least-privilege, default) + `nfs-harness-broad`
   (permissive fallback when a tight policy is missing an action), us-east-1.
2. WSL + Ansible (run bin/bootstrap-wsl.sh inside WSL).
3. EC2 key pair named per ssh_key_name; matching .pem at ~/.ssh/nfs-harness.pem (HARNESS_SSH_KEY).

## Notes
- Default region us-east-1, override in tfvars. AWS profile default "nfs-harness-tight"
  (least-privilege); flip aws_profile to "nfs-harness-broad" to unblock a missing IAM action.
- The dynamic instance_market_options block (the originally-flagged risk spot)
  validates clean under AWS provider v5.100.0.
- AL2023 AMI used everywhere; swap to Ubuntu via the data.tf name filter if preferred.
- Guardrail is intentionally out-of-band: it terminates by tag and leaves TF
  state stale; reconcile with `terraform apply`/`refresh`. Starts armed
  (teardown_dry_run=false); set true to observe-only.
- vi is the editor of choice for this project (not nano).
