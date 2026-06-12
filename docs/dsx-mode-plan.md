# DSX dual-protocol mode — build plan for nfs-harness

Goal: add a `dsx_mode` that turns the `self_managed` backend into a faithful model
of the Hammerspace **DSX protocol-portal containerization** John described — host
kernel **NFSv4.2** as the primary path, plus a **containerized NFSv3 portal** in
its own network namespace (cgroup-capped) on `:2049`. Built from kernel primitives
(netns + veth + cgroup v2) so it demonstrates container internals, not Docker magic.

This slots into seams the repo already has. It is additive and default-off, so
every existing run (EFS, plain self_managed, benchmarks) is untouched.

---

## Where it plugs into the existing architecture

- **`nfs_backend = self_managed`** is the host. DSX only makes sense on a server
  you control; EFS is managed and can't host the portal. Gate on this.
- **`roles/nfs_server`** already owns the server node config (plain nfsd + the
  optional `tc` egress cap). The DSX layout is a *conditional task file* inside
  this role — same layer, same owner, no new role needed.
- **`bin/harness`** already threads flags → TF vars. Add one flag the same way.
- **Observability plane** needs zero changes — node_exporter mountstats already
  captures per-mount NFS metrics, so 4.2-vs-v3 shows up in Grafana for free.

See `dsx-mode-plan.mermaid` for the visual.

---

## The one mechanism it rests on (already proven)

A network namespace has its **own port space**. Verified standalone: bind
`127.0.0.1:2049` in the host ns, then again inside `unshare --net` — both succeed,
no `EADDRINUSE`. That is exactly what lets the DSX host-4.2 nfsd and the
namespaced v3 nfsd both own `:2049`. This is the load-bearing claim for the whole
feature; it holds.

---

## Build sequence (small, testable commits)

### Step 1 — Terraform variable + validation
**File:** `terraform/variables.tf`
- Add `dsx_mode` (bool, default `false`).
- Validation: `dsx_mode == false || nfs_backend == "self_managed"` with a clear
  error. Mirrors how `nfs_backend` is already validated.
- `terraform validate` → expect clean. **Commit.**

### Step 2 — Surface dsx_mode to the config layer
**File:** `terraform/nfs_backend.tf` (the self_managed branch) + `outputs.tf`
- Pass `dsx_mode` to the server node where the wrapper builds the Ansible
  inventory — either as an instance tag or an output the `harness` wrapper reads
  into a host var. Match whatever pattern `nfs_backend` / `server_egress_cap_mbit`
  already use so it's consistent.
- `terraform plan` with `-var dsx_mode=true -var nfs_backend=self_managed` →
  expect no resource diff yet (just var plumbing). **Commit.**

### Step 3 — The DSX task file (the actual work)
**File:** `ansible/roles/nfs_server/tasks/dsx.yml` (new), imported from the role's
`main.yml` behind `when: dsx_mode | default(false) | bool`.
Tasks, in order:
1. Install `nfs-utils` + `iproute` (AL2023 `dnf`; the repo standardizes on AL2023).
2. Create export dirs: host 4.2 export + portal v3 export.
3. Ensure host kernel nfsd is up and exporting 4.2 (likely already true from the
   base role — make it idempotent, don't double-export).
4. `ip netns add dsx-v3`; `lo up`; veth pair; push one end into the ns; assign
   `10.200.0.1` (host) / `10.200.0.2` (ns); both up.
5. cgroup v2: `mkdir /sys/fs/cgroup/dsx-v3`; set `cpu.max` (0.5 CPU) + `memory.max`
   (256 MiB); ensure `+cpu +memory` in `subtree_control`.
6. Inside the ns: rpcbind + `exportfs` the portal dir + `rpc.nfsd --nfs-version 3
   --no-nfs-version 4` + `rpc.mountd`. Drop the helper PIDs into the cgroup.
7. Install a `dsx-portal.service` systemd unit (oneshot, RemainAfterExit) so the
   layout survives reboot; `ExecStop` tears the ns/veth/cgroup down.
- Reuse the standalone `dsx-container-lab.sh` as the script the unit runs — single
  source of truth between "what I study by hand" and "what the role ships."
  Drop it at `ansible/roles/nfs_server/files/dsx-container-lab.sh`.

### Step 4 — Wire the harness flag
**File:** `bin/harness`
- Add `--dsx-mode` to the `up` flag parser → exports `TF_VAR_dsx_mode=true`.
- Refuse early (friendly error) if combined with `--nfs efs`, so the failure is at
  the wrapper, not deep in a TF validation trace.
- Update the inline flag help + the README flag list. **Commit.**

### Step 5 — Client-side: mount both protocols
**File:** `ansible/roles/nfs_client` (or a small `dsx` block, gated on the same var)
- When `dsx_mode`, mount **two** points on each client: 4.2 → host export, v3 →
  portal veth IP. Distinct subdirs so the existing `fio` workload writes to both.
- This is what makes the Grafana comparison meaningful (two mounts, two protocols,
  one workload). **Commit.**

### Step 6 — Validate end to end on a spot instance
- `./bin/harness up --nfs self_managed --dsx-mode --clients 2`
- On the server: `lsns`, `ip netns exec dsx-v3 ss -tlnp` (v3 :2049 in-ns),
  `cat /sys/fs/cgroup/dsx-v3/cpu.max`.
- From a client: mount both, confirm `nfsstat -m` shows 4.2 on one, v3 on the other.
- Grafana: confirm both mounts report mountstats.
- `./bin/harness down` → clean. **Commit + screenshot for the interview.**

### Step 7 — Docs
- `docs/dsx-mode.md`: what it models, the netns/cgroup mechanism, the proven
  port-space claim, the four talking points (below), and the honest scope note.
- One line + diagram link in `README.md` under the backend/toggle section.
- Add to the README TODO that this is the seam where a real DSX/Hammerspace
  backend would later slot in (you already list "wire in the actual storage
  product as a third nfs_backend option").

---

## Interview talking points this unlocks

1. **Why a container at all** — kernel nfsd is host-global, so a *second*
   independent v3 server needs its own netns. Architectural necessity, **not**
   (as I first guessed on the call) autoscaling/failover. The cgroup cap is the
   resource-isolation bonus, not the reason.
2. **Port coexistence** — per-netns port space → host `:2049` (4.2) and portal
   `:2049` (v3) never collide; this is the DSX design exactly.
3. **A container, decomposed** — namespaces (what it sees) + cgroups (what it can
   use) + overlay rootfs; runc/containerd/Docker sit on top of these syscalls.
4. **I built it** — "after the call I stood up the netns isolation myself and wired
   it into my harness so I can pump a DSX-style node out in AWS on demand."

---

## Scope honesty (say this if asked)

Models the DSX *protocol-portal containerization* only — no Anvil/metadata plane,
no DRBD, no flex-files parallelism. Deliberate: it's the one detail worth owning
cold. The `nfs_backend` toggle is the seam where a real DSX would later slot in.

---

## Commit order summary
1. TF var + validation
2. TF → inventory plumbing
3. `nfs_server/tasks/dsx.yml` + bundled script  ← the meat
4. `bin/harness --dsx-mode`
5. client dual-mount
6. e2e validation on spot
7. docs + README

Each step is independently testable; 1–2 are no-op-safe, 3 is where it comes alive.
