# Findings & Fixes — write-path saturation (20-client self-managed run)

Diagnosis from the live overnight run: 1 self-managed NFS server (`10.42.1.26`)
exporting `/srv/nfs/share` to 20 clients over NFSv4.1/TCP, one mount and one TCP
connection per client. Single Prometheus scraping 21 node_exporters (job
`nfs_fleet`), 4-panel Grafana dashboard.

This document records what the metrics actually show, the root cause, and the
concrete fixes — both quick corrections and the re-architecture that turns each
confound into a deliberate test axis.

---

## Bottom line

The rig is an accidental write-path saturation test. The lone server's inbound
network link (~256 Mbps, ~31.9 MB/s, ruler-flat for the whole window) is pinned
at capacity by the NFS WRITE traffic itself. End-to-end WRITEs take ~20 seconds,
the fleet sits at ~45% iowait (not compute), reads stay healthy, and the server
looks idle (NVMe 12% util, load 0.32, ~18% CPU). All four dashboard panels read
green the entire time. None of them can see the 20-second write latency.

The constraint is the network, not threads, not disk, not CPU. Fixing nfsd
threads or storage would change nothing.

---

## Corrected picture (important)

An earlier read of this run guessed that ~24 MB/s of the server's inbound was
"competing non-NFS noise." That was wrong, and the correction matters:

- Mountstats wire counters show **NFS WRITE payload alone is ~31.6 MB/s** on the
  wire (~89 KB per WRITE RPC x ~358 WRITE/s), which matches the server's pinned
  ~31.9 MB/s rx almost exactly. **There is no foreign flow.**
- The ~7.4 MB/s that reaches disk is simply what survives **server-side
  page-cache coalescing** — the workload rewrites the same extents and ships each
  rewrite over the wire, so wire bytes >> disk bytes.

So: your own write traffic saturates the server's inbound cap. Three different
"throughputs" disagree by ~4x, and that disagreement is itself a finding:

| Layer | Rate | What it is |
|---|---|---|
| Application (mountstats app bytes) | ~24.7 MB/s | bytes the workload thinks it wrote |
| Wire (mountstats RPC payload) | ~31.7 MB/s | rewrite shipping + page-alignment inflation |
| Disk (nvme writes) | ~7.9 MB/s | what survives server cache coalescing |

---

## Detailed findings

### 1. Server inbound link saturated flat
Server rx on `ens5` = 31.9 MB/s (~255 Mbps) +/-0.06% for the entire window —
ruler-flat while everything else oscillates. That is a hard bandwidth cap being
hit continuously: either a burstable-instance baseline after burst credits are
exhausted, or an undocumented throttle. Clients collectively transmit a matching
flat ~33 MB/s at it.

### 2. Writes catastrophically slow, reads fine
Per-op averages (independent mountstats counters, 5-minute windows):

| Op | Rate | Server RTT | Client queue | Total |
|---|---|---|---|---|
| WRITE | 358/s | 1.2 s | 18.4 s | ~20 s |
| COMMIT | 56/s | 57 ms | — | 460 ms |
| READ | 384/s | 12.7 ms | — | 13 ms |

The asymmetry is the tell. Reads flow **out** of the server (tx oscillates
freely, 5–39 MB/s); writes flow **in** through the saturated rx link. TCP
backpressure pushes the wait back into each client's RPC layer — hence 18.4 s of
queue time before transmission and ~447 RPC-seconds in flight fleet-wide. Steady
across all 30 min (20–26 s), so this is **equilibrium saturation, not a building
backlog**. Per-client latency ranges 6 s (`10.42.1.94`) to 31.6 s (`10.42.1.214`).

### 3. The server is loafing
NVMe 12% util, 1.5 ms write await, load/cores 0.32, ~18% CPU. The 8 nfsd threads
are not the constraint; the NIC is. Tuning threads or disk changes nothing until
the network is fixed.

### 4. The "CPU busy" panel is misleading
The query is `100 - idle`, which counts iowait. Fleet "busy" = 45.8%, but 44.3
points of that is **iowait** — real compute is ~1.5%. The fleet isn't working,
it's blocked waiting on NFS writes.

### 5. Apps write 24.7 MB/s; only 7.4 MB/s ships to disk
Client page caches absorb rewrites (~3.3:1 coalescing), dirty pages stay bounded
(50–157 MB/node), so buffered writers survive. Anything that `fsync`s eats the
460 ms COMMIT / 20 s WRITE path. Reads can't coalesce: client 23.54 MB/s vs
server 23.57 MB/s — an exact match.

### 6. One straggler skews comparison
`10.42.1.214` sat idle (1.4% CPU, zero iowait) until ~08:34, then its generator
engaged and it joined at 50% busy / 49% iowait, immediately becoming the worst
write-latency client (31.6 s) with the most dirty pages. Its measurement window
is not comparable to the other 19.

---

## Root cause

One server, one mount, one TCP connection per client, writing rewritten (not
unique) data into a ~256 Mbps inbound cap, driven by **closed-loop generators**
that self-throttle to whatever the pipe can drain. The result is an equilibrium
the harness created, measured by a dashboard that cannot see latency.

---

## Fixes — checklist

### A. Platform (do these first) — DONE 2026-06-11
- [x] Move the NFS server off any burstable instance class to guaranteed-bandwidth
      (c5n / m5n / m6in), same AZ, cluster placement group. Never benchmark on
      burstable — burst credits make results a function of wall-clock time, not
      your variables.
      → `server_instance_type` default is now `c5n.large` (network-optimized,
      guaranteed bandwidth); new `aws_placement_group.cluster` (strategy=cluster,
      single AZ) with the server in it by default. Clients join only when
      `cluster_clients=true` and they're a non-burstable type (t3 isn't a valid
      cluster-PG type). IAM: added `ec2:Create/DeletePlacementGroup` (gap #9).
- [x] If a constrained link is wanted as a *variable*, impose it explicitly with
      `tc` so it's reproducible and documented, not an accident of credit
      exhaustion.
      → new `nfs_server` Ansible role applies a `tbf` egress cap from
      `server_egress_cap_mbit` (default 0 = unlimited); documented, version-
      controlled, identical run to run.
- [x] Add node_exporter's `ethtool` collector and chart ENA
      `bw_in_allowance_exceeded` / `bw_out_allowance_exceeded` to confirm when the
      NIC cap is the limit.
      → `--collector.ethtool` added to node_exporter (with `CAP_NET_ADMIN` on the
      systemd unit so the non-root service can read the counters); new Grafana
      panel "ENA NIC allowance exceeded (events/s)" plus a network-transmit panel.

### B. Generators (the biggest design flaw)
- [ ] Switch from closed-loop to **open-loop, fixed-rate** generators
      (`fio --rate=... --iodepth=...`), swept stepwise, to produce
      latency-vs-offered-load curves. The knee of that curve is the real result;
      a single saturated point is not.
- [ ] Barrier-start all generators so every node's window is comparable (fixes the
      `.214` straggler).
- [ ] Add a fixed warmup that is discarded, then synchronized measurement phases.

### C. Workload data shape
- [ ] Decide which layer is under test, then make the data match it:
  - [ ] Storage/server path under test -> write **unique** data (large working
        set, randwrite or append) so app ≈ wire ≈ disk and the number means
        something.
  - [ ] Caching/rewrite behavior under test -> keep rewrites but **instrument and
        label all three layers** (app / wire / disk). Don't let the workload pick
        accidentally.

### D. Data-path scaling
- [x] **Export off the root disk onto a dedicated, provisioned-throughput volume.**
      Added 2026-06-11 after Run 2 (below) showed the export pinned at the gp3
      125 MB/s baseline. New `server_data_volume_*` vars: a separate gp3 (or io2)
      device at 500 MB/s / 4000 IOPS, mounted at `/srv/nfs/share`; root shrinks to
      OS-only.
- [x] **Bypass EBS entirely with instance-store NVMe.** Run 3 showed the dedicated
      volume's own limits are no longer binding — the *instance's* EBS pipe is
      (c5n.large baseline ≈ 0.65 Gbit/s). Resolved 2026-06-11: server defaults to
      `m5dn.large` (enhanced net + local NVMe) and `server_use_instance_store=true`,
      so the export rides the local NVMe and EBS leaves the data path. Toggle off to
      fall back to the provisioned-throughput EBS volume for non-`d` types. *(Awaits
      a Run 4 to confirm the local NVMe clears 0.65 Gbit/s and the next cap appears —
      expected to be the burstable clients, now also fixed: client default →
      `c5n.large`.)*
- [ ] `nconnect=4–16` to parallelize per-client transport and stop writes
      head-of-line-blocking reads on the shared TCP connection.
- [ ] `wsize=1M` (currently shipping ~89 KB per WRITE).
- [ ] Raise nfsd threads 8 -> ~64 (irrelevant today; it's the *next* bottleneck the
      moment the NIC is fixed).
- [ ] Set `sync` vs `async` export explicitly and record the choice.
- [ ] For horizontal-scale questions: multiple servers or pNFS/FlexFiles.

### E. Orchestration & provenance
- [ ] Record per-run metadata alongside metrics: instance types, mount options,
      generator params, export options.
- [ ] Push phase boundaries into Grafana annotations.
- [ ] Pull results programmatically via PromQL rather than eyeballing panels.

### F. Dashboard (so this failure class is visible next time)
- [x] Add per-op **latency** panel (RTT vs total request time from mountstats —
      the gap is client-side queueing). Done 2026-06-11.
- [x] **Split iowait out of the CPU panel** — the panel now excludes iowait, and a
      separate iowait panel sits beside it. Done 2026-06-11 (Run 2 proved why: a
      disk-bound server read 99.8% "busy", 91 pts of it iowait).
- [x] Add **disk throughput + utilization** panels — a flat-topped throughput line
      at ~100% util is the volume cap. Done 2026-06-11.
- [x] Add ENA allowance-drop panel. Done (Platform A).
- [ ] Show **wire-level vs app-level** throughput side by side.
- [ ] Add server NIC rx/tx with a **capacity line**.
- [ ] Add nfsd thread / RPC stats.

---

## Run 2 (2026-06-11) — Platform A validated; bottleneck moved

Re-ran on the network-optimized server (c5n.large). Verified via raw PromQL.

**Platform A confirmed fixed:** server NIC clean — **zero** `bw_*_allowance_exceeded`
on the server, ~0.5 Gbit/s each way against ~3 Gbps available. The 256 Mbps wall
is gone. Also clean: zero RPC retransmissions, no pps/conntrack events, steal ~0.

**New bottleneck #1 — server is EBS-throughput-bound (same failure class).**
`nvme0n1` flat-topped at exactly **125 MB/s** combined since minute one — the gp3
*baseline*, and the export was on the 100 GB **root** volume. IOPS only ~1.8k/3k,
so throughput bound first. Disk await 5 ms but op RTT 480–560 ms: requests queue
behind the cap (avg queue ~9). The "CPU 100%" was a lie — 91% iowait, 0.1% user.
→ **Fixed:** dedicated provisioned-throughput export volume (§D), iowait split out
of the CPU panel + disk panels added (§F).

**New bottleneck #2 — clients still burstable (the rule only reached the server).**
`bw_out_allowance_exceeded` continuous on two t3.small clients (~180/s, ~170/s)
since run start; the other three ~15–20/s. Not yet binding (server disk is slower)
but it's credit-dependent — the wall-clock problem again, client-side — and becomes
the limit the moment the disk is fixed. → **Guidance added** to use c5n/m5n load
generators for benchmark runs (which also unlocks `cluster_clients`); the ethtool
panel is what surfaced this.

## Run 3 (2026-06-11, ~21:23) — volume fix validated; cap moved to instance EBS

Fresh fleet (server `.126`, clients `.6/.29/.30/.69/.125`), same c5n.large server.

**Volume fix confirmed.** Export is now on the dedicated 100 GB xfs volume
(`nvme1n1` → `/srv/nfs/share`); the root disk is idle. The new panels (CPU
excl-iowait, iowait, per-device disk) are live and reading correctly. Server NIC
still clean: 291 Mbit/s tx, zero ENA events, zero RPC retransmissions.

**Bottleneck #1 moved up a layer — instance EBS bandwidth, not the volume.**
`nvme1n1` flat-tops at **77.4 MiB/s combined = 0.65 Gbit/s exactly** — the
documented **c5n.large per-instance EBS baseline**. Pinned there from minute one:
100% util, ~1,090 IOPS @ ~72 KiB, queue ~6.5. The *volume's* own limits aren't
binding (well under 125 MB/s / 3000 IOPS) — the *instance's* EBS pipe is. Net
effect is worse than Run 2: iowait 95%, client RTT 0.66–1.25 s (was ~0.5),
per-client ops 380 → ~215, per-client NFS throughput ~14.5 MB/s. No EBS burst
appeared (c5n.large can burst 4.75 Gbit/s ~30 min/24 h) — likely spent during
dataset laydown before measurement; CloudWatch `EBSByteBalance%` would confirm.
The irony: c5n was picked for its big NIC, but `.large` has one of the *smallest*
EBS baselines in the family. → **Fix queued in §D** (go c5n.xlarge+, or an
instance-store NVMe type to bypass EBS, or document 0.65 Gbit/s as the constraint).

**Bottleneck #2 unchanged — clients still burstable.** `bw_out_allowance_exceeded`
continues: `.69` ≈ 109/s, `.29` ≈ 41/s, others 4–9/s — at only ~60 Mbit/s avg tx
each (sub-second bursts getting clipped, asymmetrically per node). The planned
client fix (c5n/m5n, or an explicit tc cap) didn't make this iteration. Not the
binding constraint today, but it adds node-dependent tail latency, is
credit/wall-clock dependent, and becomes the limit the moment #1 is fixed.

Each fix is working and peeling back the next layer: network ✓, root volume ✓,
now **instance EBS bandwidth**, with the burstable clients queued as the layer
after that.

## Run 4 (planned) — diagnose the asymmetric client clipping BEFORE fixing it

**Observation (Run 3 fleet).** `bw_out_allowance_exceeded` is asymmetric across five
*identical* c5n.large clients: ~2 heavy (450–490 ev/s), ~1 medium (rising), ~2
near-zero — while every client averages only ~80–115 Mbit/s tx. Sub-baseline
average + heavy clipping ⇒ **microburst** clipping, not sustained-rate exhaustion.
The same 2/1/2 shape appeared on the t3 iteration too.

**What the code rules out.** The load is byte-identical per client
([`workload/run-load.sh`](../workload/run-load.sh), [`roles/workload`](../ansible/roles/workload)):
same `randrw 64k 512M numjobs=4`, per-host subdir, no index/hostname branching. So
the asymmetry is **not** a per-client fio-mix difference. Two structural facts make
bursts likely: `--direct=0` (buffered → kernel *writeback* flushes at line rate) and
five **free-running** `LOOP=true` fio cycles that drift out of phase.

**Hypothesis.** The "heavy" clients are whichever are mid **file-laydown** (write-heavy)
at scrape time; buffered writeback flushes as line-rate microbursts that drain the ENA
token bucket. The 2/1/2 shape is a *snapshot of five desynced oscillators*, not a
per-instance defect — so the heavy set should **migrate** over time.

**Decision criterion (the one observation that settles it):**
- Heavy set **migrates** across clients over ~10 min, and each client's clip spike
  tracks its own WRITE spike → **phase-desync artifact** (software-fixable). Expected.
- Heavy set **fixed** to the same instance IDs → **structural** (host/placement); chase
  the network path instead.

**Protocol.**
1. Spin up `--nfs self_managed --capacity spot`, **`--cluster-clients`** (the Run 3
   clients were NOT in the PG — `cluster_clients` defaulted false; co-locate them to
   remove placement as a variable). Capture `client_placement_groups` output as proof.
2. Let it run **≥15 min** (several 120 s fio cycles so phase drift is observable).
3. Watch the two **DIAG** dashboard panels together: *per-client WRITE MB/s* (laydown)
   vs *per-client tx-allowance clips/s*. Confirm (a) spikes co-occur per client, (b) the
   heavy set rotates. Note load is unchanged on purpose — this run only *explains*.

**Fix (deferred to Run 5, intent = realistic app behavior — keep `direct=0`):** pace at
the NIC with an `fq` qdisc on clients (generalize the server's `tc`/`server_egress_cap_mbit`
into a client-side `fq`/`client_pacing` option) and add a **phase-sync barrier** (or a
measurement window ≥ one full loop cycle) so per-client tail-latency comparisons average
over phases instead of catching everyone at a random point. Optional exactness upgrade: a
node_exporter **textfile** phase-marker emitted by `run-load.sh` at each pass boundary.

## Re-validation sequence (after fixes)

1. [ ] Baseline **1 client** against the fixed server — expect ms-level WRITE RTT.
2. [ ] Sweep **1 -> 20 clients** to find where queueing starts.
3. [ ] Reintroduce constraints (bandwidth cap, thread limit) **one at a time** as
       controlled variables.

Each confound found in this run becomes a deliberate axis instead of a hidden
variable.

---

## One-sentence version

The current rig measures TCP queueing into an accidentally starved NIC using
self-throttling generators and a dashboard that can't see latency — fix the
instance class, go open-loop with unique data, and instrument the write path end
to end.
