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

### A. Platform (do these first)
- [ ] Move the NFS server off any burstable instance class to guaranteed-bandwidth
      (c5n / m5n / m6in), same AZ, cluster placement group. Never benchmark on
      burstable — burst credits make results a function of wall-clock time, not
      your variables.
- [ ] If a constrained link is wanted as a *variable*, impose it explicitly with
      `tc` so it's reproducible and documented, not an accident of credit
      exhaustion.
- [ ] Add node_exporter's `ethtool` collector and chart ENA
      `bw_in_allowance_exceeded` / `bw_out_allowance_exceeded` to confirm when the
      NIC cap is the limit.

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
- [ ] Add per-op **latency** panel (request / response / queue time from
      mountstats — counters already exist).
- [ ] Show **wire-level vs app-level** throughput side by side.
- [ ] Add server NIC rx/tx with a **capacity line**.
- [ ] Add ENA allowance-drop panel.
- [ ] Add nfsd thread / RPC stats.
- [ ] **Split iowait out of the CPU panel** — 44 of 46 "busy" points were
      processes waiting on NFS, not compute.

---

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
