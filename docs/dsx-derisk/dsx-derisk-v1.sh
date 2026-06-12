#!/bin/bash
###############################################################################
# DSX de-risk probe — proves (or disproves) the load-bearing kernel mechanics
# the dsx_mode feature rests on, on THIS box's real kernel, before we commit to
# the in-kernel-nfsd design.
#
# It is a teaching artifact too: each CLAIM block explains the kernel concept it
# exercises. Run as root on a fresh AL2023 self_managed server (nfs-utils + the
# host nfsd are already up from cloud-init).
#
#   sudo bash dsx-derisk.sh
#
# Output: one "CLAIM N ... PASS/FAIL" line per mechanism, plus a final verdict.
# Idempotent-enough for a throwaway box: a cleanup trap tears down everything it
# creates so a re-run starts clean-ish.
###############################################################################
set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  ✅ PASS: $*"; PASS=$((PASS+1)); }
no()   { echo "  ❌ FAIL: $*"; FAIL=$((FAIL+1)); }
hdr()  { echo; echo "=== $* ==="; }

NS=dsx-v3
VETH_H=veth-dsx-h          # host end
VETH_C=veth-dsx-c          # container (ns) end
HOST_IP=10.200.0.1
NS_IP=10.200.0.2
CG=/sys/fs/cgroup/$NS

cleanup() {
  hdr "cleanup"
  umount /mnt/dsx-h42 2>/dev/null
  umount /mnt/dsx-v3  2>/dev/null
  # stop in-ns daemons (they live in the ns; kill by the ns's pids)
  ip netns pids $NS 2>/dev/null | xargs -r kill 2>/dev/null
  ip netns del $NS 2>/dev/null
  ip link del $VETH_H 2>/dev/null
  [ -d "$CG" ] && rmdir "$CG" 2>/dev/null
  exportfs -u 127.0.0.1:/export/dsx-host42 2>/dev/null
  rm -rf /export/dsx-host42 /export/dsx-portal-v3 2>/dev/null
  echo "  (cleanup done)"
}
trap cleanup EXIT

echo "kernel: $(uname -r)   nfs-utils: $(rpm -q nfs-utils 2>/dev/null || echo '?')"

###############################################################################
# CLAIM 1 — A network namespace has its OWN port space.
#
# This is THE foundational claim: it's why host nfsd (NFSv4.2) and the portal
# nfsd (NFSv3) can BOTH own :2049 with no EADDRINUSE. A netns is an isolated copy
# of the kernel's whole network stack — interfaces, routing tables, AND the
# socket/port tables. Port 2049 in the host ns and 2049 in dsx-v3 are different
# kernel objects. We prove it the cheapest possible way: bind a plain TCP socket
# to :2049 in BOTH namespaces at once.
###############################################################################
hdr "CLAIM 1 — per-netns port space (both bind :2049 simultaneously)"
ip netns add portspace-test 2>/dev/null
ip netns exec portspace-test ip link set lo up
# host-side listener on 2049
python3 -c 'import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("0.0.0.0",2049)); s.listen(1); time.sleep(8)' &
HOST_BIND=$!
# ns-side listener on 2049 — same port number, different namespace
ip netns exec portspace-test python3 -c 'import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("0.0.0.0",2049)); s.listen(1); time.sleep(8)' &
NS_BIND=$!
sleep 2
if kill -0 $HOST_BIND 2>/dev/null && kill -0 $NS_BIND 2>/dev/null; then
  ok "both :2049 binds are alive — separate port spaces confirmed"
else
  no ":2049 collided across namespaces (one bind died) — foundational claim broken"
fi
kill $HOST_BIND $NS_BIND 2>/dev/null
ip netns del portspace-test 2>/dev/null

###############################################################################
# CLAIM 2 — The HOST kernel nfsd serves NFSv4.2.
#
# Baseline: the primary DSX path is host-kernel NFSv4.2. The box already runs
# nfs-server from cloud-init; we add a dedicated test export for 127.0.0.1 (the
# real export is CIDR-scoped) and loopback-mount it forcing vers=4.2.
###############################################################################
hdr "CLAIM 2 — host kernel nfsd serves NFSv4.2"
mkdir -p /export/dsx-host42 /mnt/dsx-h42
chmod 777 /export/dsx-host42
exportfs -o rw,sync,no_subtree_check,no_root_squash 127.0.0.1:/export/dsx-host42
systemctl is-active --quiet nfs-server || systemctl start nfs-server
if mount -t nfs -o vers=4.2 127.0.0.1:/export/dsx-host42 /mnt/dsx-h42 2>/tmp/m42.err; then
  V=$(nfsstat -m | awk '/dsx-h42/{getline; print}' | grep -o 'vers=[0-9.]*')
  echo "  mount opts: $V"
  echo dsx-host-test > /mnt/dsx-h42/probe && [ -f /mnt/dsx-h42/probe ] && ok "host NFSv4.2 mounted + read/write ($V)" || no "host v4.2 mount up but I/O failed"
else
  no "host v4.2 mount failed: $(cat /tmp/m42.err)"
fi

###############################################################################
# CLAIM 3 — A SECOND, independent in-kernel nfsd inside the netns, NFSv3-only.
#
# THE risky one. We build the container's network by hand:
#   • ip netns add dsx-v3            -> a fresh, empty network stack
#   • veth pair                      -> a virtual cable; one end stays on the
#                                       host, the other is pushed into the ns,
#                                       so host(.1) <-> ns(.2) can talk
#   • rpcbind/mountd/nfsd in the ns  -> NFSv3 needs the portmapper (rpcbind:111)
#                                       + mountd; v4 doesn't. We start nfsd with
#                                       --no-nfs-version 4 so the portal is v3-ONLY.
# The open question this answers: is in-kernel nfsd netns-aware on THIS kernel —
# does `ip netns exec dsx-v3 rpc.nfsd` stand up service scoped to that namespace,
# coexisting with the host nfsd that's already running?
###############################################################################
hdr "CLAIM 3 — netns-isolated in-kernel nfsd, NFSv3-only"
mkdir -p /export/dsx-portal-v3 /mnt/dsx-v3
chmod 777 /export/dsx-portal-v3
echo portal-v3-data > /export/dsx-portal-v3/portalfile

# 3a. namespace + virtual cable
ip netns add $NS
ip netns exec $NS ip link set lo up
ip link add $VETH_H type veth peer name $VETH_C
ip link set $VETH_C netns $NS
ip addr add $HOST_IP/24 dev $VETH_H; ip link set $VETH_H up
ip netns exec $NS ip addr add $NS_IP/24 dev $VETH_C
ip netns exec $NS ip link set $VETH_C up
if ping -c1 -W2 $NS_IP >/dev/null 2>&1; then ok "veth link up (host $HOST_IP <-> ns $NS_IP)"; else no "veth link dead"; fi

# 3b. RPC services INSIDE the namespace
ip netns exec $NS rpcbind 2>/tmp/rpcbind.err
sleep 1
ip netns exec $NS exportfs -o rw,sync,no_subtree_check,no_root_squash,insecure ${NS_IP%.*}.0/24:/export/dsx-portal-v3 2>/tmp/exp.err
# v3-only nfsd in the ns (8 threads), plus mountd
ip netns exec $NS rpc.nfsd --nfs-version 3 --no-nfs-version 4 8 2>/tmp/nfsd.err
ip netns exec $NS rpc.mountd --no-nfs-version 4 2>/tmp/mountd.err
sleep 2
# what's listening inside the ns?
echo "  in-ns listeners:"; ip netns exec $NS ss -tlnp 2>/dev/null | grep -E ':2049|:111|:20048' | sed 's/^/    /' || echo "    (none)"

# 3c. mount the portal over the veth, forcing v3
if mount -t nfs -o vers=3,proto=tcp,mountproto=tcp $NS_IP:/export/dsx-portal-v3 /mnt/dsx-v3 2>/tmp/mv3.err; then
  V=$(nfsstat -m | awk '/dsx-v3/{getline; print}' | grep -o 'vers=[0-9.]*')
  echo "  mount opts: $V"
  if [ "$(cat /mnt/dsx-v3/portalfile 2>/dev/null)" = "portal-v3-data" ]; then
    ok "netns NFSv3 portal mounted + read over veth ($V)"
  else no "portal mounted but read failed"; fi
else
  no "portal v3 mount failed: $(cat /tmp/mv3.err); nfsd.err=$(cat /tmp/nfsd.err)"
fi

###############################################################################
# CLAIM 4 — Version isolation: host stays 4.2, portal is v3-only (refuses 4.x).
###############################################################################
hdr "CLAIM 4 — version isolation between host and portal"
STILL42=$(nfsstat -m | awk '/dsx-h42/{getline; print}' | grep -o 'vers=4.2')
[ "$STILL42" = "vers=4.2" ] && ok "host export still NFSv4.2 after portal came up" || no "host export lost its v4.2"
# the portal should REFUSE v4.2
if mount -t nfs -o vers=4.2 $NS_IP:/export/dsx-portal-v3 /mnt/dsx-v3-x 2>/tmp/v4x.err; then
  no "portal accepted v4.2 — it is NOT v3-only"; umount /mnt/dsx-v3-x 2>/dev/null
else
  ok "portal refused v4.2 as designed (v3-only): $(head -1 /tmp/v4x.err)"
fi

###############################################################################
# CLAIM 5 — cgroup v2 caps the USERSPACE control plane (and the honest limit:
# in-kernel nfsd threads are kthreads in the root cgroup, NOT confinable here).
###############################################################################
hdr "CLAIM 5 — cgroup v2 resource cap (and its honest boundary)"
# enable controllers at the root subtree, then make our cgroup
grep -q cpu /sys/fs/cgroup/cgroup.subtree_control || echo "+cpu +memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/tmp/cg.err
mkdir -p "$CG"
echo "50000 100000" > "$CG/cpu.max" 2>>/tmp/cg.err     # 0.5 CPU
echo "268435456"    > "$CG/memory.max" 2>>/tmp/cg.err  # 256 MiB
# move the in-ns userspace RPC helpers into the cgroup
moved=0
for p in $(ip netns pids $NS 2>/dev/null); do
  comm=$(cat /proc/$p/comm 2>/dev/null)
  if echo "$p" > "$CG/cgroup.procs" 2>/dev/null; then moved=$((moved+1)); echo "    confined pid $p ($comm)"; fi
done
[ "$(cat "$CG/cpu.max" 2>/dev/null)" = "50000 100000" ] && [ "$moved" -gt 0 ] \
  && ok "cgroup caps set (0.5 CPU / 256 MiB); $moved userspace RPC helper(s) confined" \
  || no "cgroup setup failed: $(cat /tmp/cg.err 2>/dev/null)"
# the honest part: try to confine an [nfsd] kthread — expect it to be unconfinable
NFSD_K=$(pgrep -x nfsd | head -1)
if [ -n "$NFSD_K" ]; then
  if echo "$NFSD_K" > "$CG/cgroup.procs" 2>/dev/null; then
    echo "  ⚠️  NOTE: kthread nfsd pid $NFSD_K accepted into cgroup (unusual) — verify it's actually constrained"
  else
    echo "  ⚠️  EXPECTED: [nfsd] kthread (pid $NFSD_K) cannot be moved into the cgroup —"
    echo "      the cap bounds the userspace control plane, NOT the in-kernel service threads."
    echo "      (This is the honest talking point: it's why userspace servers like ganesha exist.)"
  fi
fi

###############################################################################
hdr "VERDICT"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  ➜ in-kernel-nfsd DSX design is viable on this kernel. Proceed with Step 3."
else
  echo "  ➜ at least one load-bearing claim failed. Review above; consider the ganesha fallback for the failed piece."
fi
