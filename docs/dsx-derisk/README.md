# DSX de-risk probes — proof that the in-kernel portal design works

Before building `dsx_mode` (see [`../dsx-mode-plan.md`](../dsx-mode-plan.md)), the
load-bearing kernel claims were tested on a real AL2023 box (kernel
`6.18.33-63.124.amzn2023`, m5dn.large, 2026-06-12). Two probe iterations; the
autopsy of v1's failures is what produced the final recipe.

## Verdict

**v2: 7/7 PASS — in-kernel nfsd portal is viable, with the netns + mount-ns
recipe.** No ganesha fallback needed.

## What v1 got wrong (the teaching part)

v1 assumed `ip netns exec` was enough. It is not — two failures, both instructive:

1. **`ip netns exec` switches ONLY the network namespace.** The filesystem stays
   shared, so the portal's `rpcbind` collided with host rpcbind state in `/run`,
   and `exportfs` wrote into the *host's* `/var/lib/nfs/etab`.
2. **`rpc.nfsd` controls the nfsd instance bound to the *mount* of
   `/proc/fs/nfsd`** — and the existing mount belongs to the host netns. So v1's
   in-ns `rpc.nfsd` silently configured the *host* server (a no-op) and no socket
   ever appeared inside the namespace.

(Also: v1's CLAIM 1 "failure" was a probe bug — the host-side test bind collided
with the *real* host nfsd already on `:2049`, which is evidence the feature needs
per-netns port space, not evidence against it.)

## The proven recipe (v2, LXC-style)

Inside the netns **plus a private mount namespace** (`unshare -m`):

```sh
mount --make-rprivate /
mount -t tmpfs tmpfs /run                      # private rpcbind state
mount --bind <portal-state> /var/lib/nfs       # private etab/rmtab
mount --bind <portal-exports> /etc/exports     # portal's own export table
mount -t nfsd nfsd /proc/fs/nfsd               # THE key line — see below
rpcbind
exportfs -ra
rpc.nfsd --nfs-version 3 --no-nfs-version 4 4  # v3-ONLY server
rpc.mountd --no-nfs-version 4
```

The key line: each mount of the `nfsd` control filesystem binds to the **network
namespace of the mounting process**. A fresh mount made inside `dsx-v3` gives
`rpc.nfsd` a control handle to a second, independent in-kernel NFS server whose
sockets live in the portal's own port space. One kernel, N NFS servers, one per
netns — this is exactly the mechanism the DSX protocol portal rests on.

## What v2 proved

| # | Claim | Result |
|---|---|---|
| 1 | netns binds `:2049` while host nfsd holds host `:2049` | PASS |
| 2 | host kernel nfsd serves NFSv4.2 (mount + I/O) | PASS |
| 3 | second in-kernel nfsd inside netns+mountns, reachable over veth, NFSv3 | PASS |
| 4 | version isolation — host stays 4.2; portal **refuses** 4.2 (`Protocol not supported`) | PASS |
| 5 | cgroup v2 caps the portal's userspace plane | PASS |

**Surprise finding:** on kernel 6.18 the `[nfsd]` kernel threads were *accepted*
into the cgroup (older kernels refuse kthreads outright) — host's 8 and the
portal's 4 all migrated. Whether `cpu.max` genuinely *throttles* them under load
is still unverified → measure at step 6 (drive fio through the portal, watch
`cgroup`'s `cpu.stat` throttling counters). Until then the honest claim is
"threads join the cgroup; enforcement under load TBD."

## Bonus finding from productionizing (`dsx-portal.sh` lifecycle testing)

**The NFSv3 `root_squash` + `O_CREAT` papercut — a real v3-vs-v4.2 behavioral
difference the portal surfaced on day one.** With `root_squash` on the portal's
v3 export, a ROOT writer's `open(O_CREAT|O_WRONLY)` fails `EACCES`: the CREATE
succeeds server-side (file appears, owned `nobody`, 0644), but the open's access
check then pits **local uid 0** against the nobody-owned file — root gets no
`CAP_DAC_OVERRIDE` over NFS — and is denied as the "other" class. strace:

```
openat(O_WRONLY|O_CREAT|O_TRUNC) = -1 EACCES   <- create-and-open: denied
openat(O_WRONLY|O_TRUNC)         = 3           <- same file, no O_CREAT: works
```

Meanwhile the harness's main **NFSv4.2** export runs `root_squash` with a root
fio workload happily — v4's atomic server-side OPEN resolves create+access as the
*squashed* identity, so the papercut doesn't exist there. Non-root writers are
unaffected on both. Consequence: the portal's v3 export defaults to
`no_root_squash` (override via `DSX_EXPORT_OPTS`), documented as modeling what
legacy-v3 fabrics actually run — and the portal's readiness probe writes *data*,
not just `touch`, so this failure class can't hide behind a create-only check.

## Files

- `dsx-derisk-v1.sh` — first probe (netns-only). Kept for the autopsy value.
- `dsx-derisk-v2.sh` — the passing probe; the direct ancestor of the production
  `dsx-portal` script that `roles/nfs_server/tasks/dsx.yml` ships (step 3).

Run on a `self_managed` server: `sudo bash dsx-derisk-v2.sh` (idempotent-ish; a
cleanup trap tears down everything it creates).
