# DSX mode — dual-protocol NFS from raw kernel primitives

`--dsx-mode` turns the self-managed backend into a model of the Hammerspace
**DSX protocol-portal containerization**: the host kernel keeps serving
**NFSv4.2** as the primary path, while a **containerized NFSv3 portal** — built
from `ip netns`, `unshare -m`, a veth pair, and cgroup v2, *no Docker/runc* —
serves the same backing disk on its **own `:2049`**. Clients mount both at once;
Grafana compares the protocols live.

```
./bin/harness obs-up
./bin/harness up --nfs self_managed --dsx-mode --clients 2 --capacity spot
```

**Validated end-to-end 2026-06-12** (2 spot clients + m5dn.large server):
portal `active` via systemd, clients dual-mounted, both fio containers running,
Prometheus splitting the two exports — host 4.2 ≈ 42 MB/s / 1,269 ops/s vs the
deliberately capped v3 portal ≈ 20 MB/s / 605 ops/s.

![Plan diagram](diagrams/dsx-mode-plan.mermaid)

---

## The mechanism (and what makes it a "container")

There is no container object in the kernel. A container is a normal process the
kernel has (a) lied to about its surroundings — **namespaces** — and (b) put on
a budget — **cgroups**. The portal is exactly that, assembled by hand in
[`ansible/roles/nfs_server/files/dsx-portal.sh`](../ansible/roles/nfs_server/files/dsx-portal.sh):

1. **Network namespace** (`ip netns add dsx-v3`) — an independent copy of the
   entire network stack, *including the port table*. Host `:2049` and portal
   `:2049` are different kernel objects; no `EADDRINUSE`. This is the
   load-bearing fact of the whole design (proven standalone in
   [`dsx-derisk/`](dsx-derisk/)).
2. **veth pair** — a virtual cable; one end stays on the host (`10.200.0.1`),
   the other is pushed into the namespace (`10.200.0.2` — the IP clients mount).
3. **Mount namespace** (`unshare -m`) — the part `ip netns exec` does NOT give
   you, and the v1 de-risk failure that defined the design: the portal gets a
   private `/run` (rpcbind state), private `/var/lib/nfs` (etab/rmtab), its own
   bind-mounted `/etc/exports`, and — the key line —

   ```sh
   mount -t nfsd nfsd /proc/fs/nfsd
   ```

   Each mount of the `nfsd` control filesystem **binds to the network namespace
   of the mounting process**. A fresh mount inside `dsx-v3` hands `rpc.nfsd` a
   second, namespace-scoped in-kernel NFS server. One kernel, N NFS servers.
4. **v3-only services** in the namespace: `rpcbind` (`:111`), `exportfs`,
   `rpc.nfsd --nfs-version 3 --no-nfs-version 4`, `rpc.mountd` pinned to
   `:20048` (dynamic ports can't be firewalled; pinning also lets clients pass
   `mountport=` and skip rpcbind entirely).
5. **cgroup v2 cap** — `cpu.max` 0.5 CPU, `memory.max` 256 MiB on the portal's
   control plane. Kernel 6.18 finding: the portal's `[nfsd]` kthreads auto-join
   the cgroup with their parent (older kernels refuse kthreads); whether
   `cpu.max` throttles them under load is measurable via `cpu.stat`.

A oneshot+`RemainAfterExit` systemd unit wraps the script: `start` blocks until
a root writer can create **and write data** through the portal (listening ≠
usable — a cold mountd auth cache EACCESes first I/O), `stop` shuts down the
per-netns kernel server via a fresh control mount (`rpc.nfsd 0`) before deleting
the namespace — killing userspace pids alone leaves kernel threads serving.

## Reaching the portal from other instances

The portal IP lives *inside* the server, so [`terraform/dsx.tf`](../terraform/dsx.tf)
(all gated on `dsx_mode`) makes the VPC treat the server as a router:

- **route**: `10.200.0.0/24` → the server's ENI, in the fleet's route table;
- **`source_dest_check = false`** on the server — EC2 otherwise drops traffic
  addressed to an IP that isn't the instance's own;
- **SG openings** for `:111` + pinned `:20048` from the clients SG (`:2049` was
  already open — SG rules are destination-IP-agnostic on the ENI).

Clients then mount both, and run the *same* fio container against each:

```
/mnt/nfs      10.42.x.x:/srv/nfs/share            vers=4.2   (host kernel)
/mnt/nfs-dsx  10.200.0.2:/srv/nfs/share/dsx-v3    vers=3,nolock,port=2049,mountport=20048
```

The portal's export dir sits **under the main share's fast disk** so the
comparison is protocol-vs-protocol, not disk-vs-disk. The dashboard's two
**DSX** panels split throughput and op-rate by `export` label.

## Findings the build surfaced

- **`ip netns exec` is not a container.** rpcbind/etab collide through the
  shared filesystem, and `rpc.nfsd` configures whichever nfsd instance owns the
  *existing* `/proc/fs/nfsd` mount (the host's). The mount namespace isn't
  optional — see [`dsx-derisk/README.md`](dsx-derisk/README.md).
- **The NFSv3 `root_squash`+`O_CREAT` papercut** (strace-proven): squashed
  root's CREATE succeeds, then the open's access check pits uid 0 against the
  nobody-owned file and EACCESes. **NFSv4.2's atomic OPEN doesn't have this** —
  the harness's main 4.2 export runs `root_squash` with a root fio happily. The
  portal therefore defaults `no_root_squash` (knob: `DSX_EXPORT_OPTS`),
  modeling what legacy-v3 fabrics actually run — a genuine v3-vs-4.2 semantic
  difference surfaced in the portal's first hour.

## Talking points

1. **Why a container at all** — kernel nfsd is host-global; a *second*
   independent v3 server needs its own netns (+ mount ns). Architectural
   necessity, not autoscaling. The cgroup cap is the bonus, not the reason.
2. **Port coexistence** — per-netns port space; host `:2049` (4.2) and portal
   `:2049` (v3) never collide. This is the DSX design exactly.
3. **A container, decomposed** — namespaces (what it sees) + cgroups (what it
   may use); runc/containerd/Docker sit on top of these same syscalls.
4. **I built it** — de-risked the kernel claims on a live box first
   (`docs/dsx-derisk/`, 7/7), then wired it into the harness so a DSX-style
   node ships on demand: `harness up --nfs self_managed --dsx-mode`.

## Scope honesty

Models the DSX *protocol-portal containerization* only — no Anvil/metadata
plane, no DRBD, no flex-files parallelism. Deliberate: it's the one detail
worth owning cold. The `nfs_backend` toggle remains the seam where a real
DSX/Hammerspace backend would slot in as a third option.
