# NFS Test Harness

Ephemeral, cost-bounded NFS load/repro test harness on AWS. Stands up an NFS
backend and a fleet of client nodes, runs a containerized workload against it,
monitors from a separate observability plane, and tears the test plane down
between runs.

See `CLAUDE.md` for full architecture, design principles, and build status.

## Quick start (from the WSL/Linux control node)

```bash
bash bin/bootstrap-wsl.sh                # once: terraform, ansible, aws, jq + creds
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit: set ssh_key_name and admin_cidr  (curl -s ifconfig.me  -> "<ip>/32")
cp terraform/observability/terraform.tfvars.example terraform/observability/terraform.tfvars

./bin/harness up --clients 3    # stand up backend + fleet, mount NFS, start the workload
./bin/harness obs-up            # bring up Prometheus/Grafana (reads scrape targets from the plane)
./bin/harness status            # Grafana URL + scrape targets
# ... watch load land in Grafana ...
./bin/harness down              # destroy the test plane; VPC + instruments + metrics stay
./bin/harness obs-down          # park observability compute; metrics volume kept
```

`terraform` alone still works for plan/validate inside `terraform/` and
`terraform/observability/` if you want the raw flow.

## Layout

```
nfs-harness/
├── CLAUDE.md                  # project context for Claude Code (read first)
├── README.md
├── terraform/                 # infrastructure — test plane + guardrail (one state)
│   ├── providers.tf  variables.tf  network.tf  data.tf
│   ├── nfs_backend.tf         # selectable EFS / self-managed
│   ├── clients.tf             # spot client fleet (var-driven count)
│   ├── teardown.tf            # Lambda + EventBridge cost guardrail
│   ├── outputs.tf  terraform.tfvars.example
│   └── observability/         # SEPARATE state — independent lifecycle
│       ├── main.tf            # persistent EBS + on-demand Prometheus/Grafana
│       └── templates/cloud-init.sh.tftpl
├── ansible/                   # config layer (node_exporter, mount, workload)
│   ├── site.yml  ansible.cfg  requirements.yml
│   └── roles/{node_exporter,nfs_client,workload}/
├── workload/                  # containerized fio NFS load generator
│   ├── Dockerfile  run-load.sh
├── lambda/teardown.py         # guardrail handler
└── bin/
    ├── harness                # up / down / obs-up / obs-down / status
    └── bootstrap-wsl.sh       # provision the WSL control node
```

## Cost posture

Idle harness ≈ cost of one small EBS volume (observability storage). Everything
else is ephemeral; the disposable client fleet runs on spot (70-90% off).
