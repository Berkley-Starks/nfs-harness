#!/bin/bash
###############################################################################
# DSX de-risk probe v2 — incorporates the v1 autopsy:
#
#   v1 CLAIM 1 "FAIL" was a probe bug: the HOST python bind collided with the
#     host's real nfsd (which already owns :2049). v2 tests the real question:
#     can a netns bind :2049 WHILE host nfsd holds it?
#   v1 CLAIM 3 failed for two reasons that teach what a container actually is:
#     (a) `ip netns exec` switches ONLY the network ns — the filesystem is
#         shared, so rpcbind/exportfs collided with host state (/run/rpcbind*,
#         /var/lib/nfs/etab);
#     (b) rpc.nfsd controls the nfsd instance bound to the MOUNT of
#         /proc/fs/nfsd. The existing mount belongs to the host netns, so our
#         in-ns rpc.nfsd just poked the HOST server (no-op).
#     Fix — the canonical LXC-style recipe: enter netns + a PRIVATE MOUNT NS,
#     give it private /run, /var/lib/nfs, /etc/exports (tmpfs/bind), mount a
#     FRESH nfsd filesystem (binds to the CURRENT netns), then rpcbind +
#     exportfs + rpc.nfsd — sockets now land inside dsx-v3.
#   v1 CLAIM 4 second check was bogus (missing mount point). v2 creates it.
#   v1 CLAIM 5: cgroup accepted what pgrep matched as "nfsd" — v2 verifies
#     whether that pid is a kthread before drawing conclusions.
###############################################################################
set -uo pipefail

PASS=0; FAIL=0
ok()  { echo "  ✅ PASS: $*"; PASS=$((PASS+1)); }
no()  { echo "  ❌ FAIL: $*"; FAIL=$((FAIL+1)); }
hdr() { echo; echo "=== $* ==="; }

NS=dsx-v3
VETH_H=veth-dsx-h
VETH_C=veth-dsx-c
HOST_IP=10.200.0.1
NS_IP=10.200.0.2
CG=/sys/fs/cgroup/$NS
PORTAL_ROOT=/srv/dsx-portal          # private state dirs for the portal
EXPORT_V3=/export/dsx-portal-v3

cleanup() {
  hdr "cleanup"
  umount /mnt/dsx-h42 /mnt/dsx-v3 /mnt/dsx-v3-x 2>/dev/null
  ip netns pids $NS 2>/dev/null | xargs -r kill 2>/dev/null
  sleep 1
  ip netns pids $NS 2>/dev/null | xargs -r kill -9 2>/dev/null
  ip netns del $NS 2>/dev/null
  ip link del $VETH_H 2>/dev/null
  [ -d "$CG" ] && rmdir "$CG" 2>/dev/null
  exportfs -u 127.0.0.1:/export/dsx-host42 2>/dev/null
  rm -rf /export/dsx-host42 "$EXPORT_V3" "$PORTAL_ROOT" /tmp/dsx-portal-inner.sh 2>/dev/null
  echo "  (cleanup done)"
}
trap cleanup EXIT

echo "kernel: $(uname -r)"

###############################################################################
# CLAIM 1 (fixed) — netns binds :2049 while the HOST's real nfsd owns it.
###############################################################################
hdr "CLAIM 1 — ns binds :2049 while host nfsd holds host :2049"
HOST_2049=$(ss -tln "sport = :2049" | grep -c 2049)
echo "  host :2049 listeners (real nfsd): $HOST_2049"
ip netns add portspace-test 2>/dev/null
ip netns exec portspace-test ip link set lo up
if [ "$HOST_2049" -ge 1 ] && \
   ip netns exec portspace-test python3 -c 'import socket; s=socket.socket(); s.bind(("0.0.0.0",2049)); s.listen(1)' 2>/tmp/c1.err; then
  ok "ns bound :2049 with host nfsd live on host :2049 — separate port spaces"
else
  no "ns could not bind :2049 alongside host nfsd: $(cat /tmp/c1.err 2>/dev/null)"
fi
ip netns del portspace-test 2>/dev/null

###############################################################################
# CLAIM 2 — host kernel nfsd serves NFSv4.2 (unchanged from v1; it passed).
###############################################################################
hdr "CLAIM 2 — host kernel nfsd serves NFSv4.2"
mkdir -p /export/dsx-host42 /mnt/dsx-h42
chmod 777 /export/dsx-host42
exportfs -o rw,sync,no_subtree_check,no_root_squash 127.0.0.1:/export/dsx-host42
if mount -t nfs -o vers=4.2 127.0.0.1:/export/dsx-host42 /mnt/dsx-h42 2>/tmp/m42.err; then
  echo dsx-host-test > /mnt/dsx-h42/probe && ok "host NFSv4.2 mounted + read/write" || no "v4.2 mounted but I/O failed"
else
  no "host v4.2 mount failed: $(cat /tmp/m42.err)"
fi

###############################################################################
# CLAIM 3 (the canonical recipe) — in-kernel NFSv3 nfsd inside netns+mountns.
#
# The teaching core. The portal "container" = netns (own net stack) + mount ns
# (own view of /run, /var/lib/nfs, /etc/exports, /proc/fs/nfsd). The fresh
# `mount -t nfsd` is the magic: the nfsd control fs binds to the netns of the
# mounting process, so rpc.nfsd inside configures THIS namespace's server and
# its sockets appear inside dsx-v3 — coexisting with the host's 4.2 server.
###############################################################################
hdr "CLAIM 3 — netns + mountns in-kernel nfsd, NFSv3-only (LXC-style recipe)"
mkdir -p "$EXPORT_V3" /mnt/dsx-v3 /mnt/dsx-v3-x
chmod 777 "$EXPORT_V3"
echo portal-v3-data > "$EXPORT_V3/portalfile"
mkdir -p "$PORTAL_ROOT"/{run,nfsstate}
cat > "$PORTAL_ROOT/exports" <<EXP
$EXPORT_V3 10.200.0.0/24(rw,sync,no_subtree_check,no_root_squash,insecure)
EXP

# 3a. namespace + veth (same as v1 — this part passed)
ip netns add $NS
ip netns exec $NS ip link set lo up
ip link add $VETH_H type veth peer name $VETH_C
ip link set $VETH_C netns $NS
ip addr add $HOST_IP/24 dev $VETH_H; ip link set $VETH_H up
ip netns exec $NS ip addr add $NS_IP/24 dev $VETH_C
ip netns exec $NS ip link set $VETH_C up
ping -c1 -W2 $NS_IP >/dev/null 2>&1 && ok "veth link up" || no "veth link dead"

# 3b. the inner script: runs inside netns(+unshare mount ns)
cat > /tmp/dsx-portal-inner.sh <<'INNER'
set -e
PORTAL_ROOT=/srv/dsx-portal
# Private mount view: changes here are invisible to the host.
mount --make-rprivate /
# private /run (rpcbind sockets/locks), /var/lib/nfs (etab/rmtab), /etc/exports
mount -t tmpfs tmpfs /run
mkdir -p /run/rpcbind
cp -a /var/lib/nfs /run/nfs-private
mount --bind /run/nfs-private /var/lib/nfs
mount --bind $PORTAL_ROOT/exports /etc/exports
# THE key line: a fresh nfsd control-fs mount, bound to THIS netns.
mount -t nfsd nfsd /proc/fs/nfsd
# RPC plane, v3-only server
rpcbind
exportfs -ra
rpc.nfsd --nfs-version 3 --no-nfs-version 4 4
rpc.mountd --no-nfs-version 4
echo "--- inner: listeners in this netns ---"
ss -tlnp | grep -E ':(111|2049|20048)' || echo "(none)"
# hold the mount ns open so the services' fs view persists
sleep 600 &
echo $! > /run/holder.pid
wait
INNER
chmod +x /tmp/dsx-portal-inner.sh

# Launch: netns via ip netns exec, mount ns via unshare -m. Background it.
ip netns exec $NS unshare -m bash /tmp/dsx-portal-inner.sh > /tmp/inner.log 2>&1 &
INNER_PID=$!
sleep 4
echo "  inner log:"; sed 's/^/    /' /tmp/inner.log
# verify from outside: sockets present inside the ns?
NS_2049=$(ip netns exec $NS ss -tln "sport = :2049" 2>/dev/null | grep -c 2049)
NS_111=$(ip netns exec $NS ss -tln "sport = :111" 2>/dev/null | grep -c 111)
echo "  ns :2049 listeners=$NS_2049  ns :111 listeners=$NS_111"

# 3c. the proof: mount the portal v3 export from the host over the veth
if mount -t nfs -o vers=3,proto=tcp,mountproto=tcp $NS_IP:$EXPORT_V3 /mnt/dsx-v3 2>/tmp/mv3.err; then
  if [ "$(cat /mnt/dsx-v3/portalfile 2>/dev/null)" = "portal-v3-data" ]; then
    ok "netns+mountns NFSv3 portal mounted + read over veth"
  else no "portal mounted but read failed"; fi
else
  no "portal v3 mount failed: $(cat /tmp/mv3.err)"
fi

###############################################################################
# CLAIM 4 (fixed) — version isolation, with a real mount point this time.
###############################################################################
hdr "CLAIM 4 — version isolation between host and portal"
nfsstat -m | grep -A1 dsx-h42 | grep -q 'vers=4.2' && ok "host export still v4.2 with portal live" || no "host export lost v4.2"
if mount -t nfs -o vers=4.2 $NS_IP:$EXPORT_V3 /mnt/dsx-v3-x 2>/tmp/v4x.err; then
  no "portal accepted v4.2 — NOT v3-only"; umount /mnt/dsx-v3-x 2>/dev/null
else
  grep -qiE "protocol|refused|not supported|timed out" /tmp/v4x.err \
    && ok "portal refused v4.2 (v3-only): $(head -1 /tmp/v4x.err)" \
    || no "v4.2 mount failed but ambiguously: $(head -1 /tmp/v4x.err)"
fi

###############################################################################
# CLAIM 5 (refined) — cgroup v2 caps the portal's userspace; verify the kthread
# question honestly (is what pgrep found actually a kernel thread?).
###############################################################################
hdr "CLAIM 5 — cgroup v2 cap + kthread boundary, verified"
grep -q cpu /sys/fs/cgroup/cgroup.subtree_control || echo "+cpu +memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
mkdir -p "$CG"
echo "50000 100000" > "$CG/cpu.max"
echo "268435456"    > "$CG/memory.max"
moved=0
for p in $(ip netns pids $NS 2>/dev/null); do
  echo "$p" > "$CG/cgroup.procs" 2>/dev/null && { moved=$((moved+1)); echo "    confined: $p ($(cat /proc/$p/comm 2>/dev/null))"; }
done
[ "$moved" -gt 0 ] && ok "cgroup caps live; $moved portal userspace pid(s) confined" || no "no portal pids confined"
# kthread check, done right: kthreads have empty /proc/<pid>/cmdline
for p in $(pgrep -x nfsd); do
  if [ -s /proc/$p/cmdline ]; then
    echo "  pid $p 'nfsd' has a cmdline → USERSPACE process (v1's 'accepted into cgroup' explained)"
  else
    if echo "$p" > "$CG/cgroup.procs" 2>/dev/null; then
      echo "  ⚠️ kthread $p accepted into cgroup — genuinely unusual, investigate"
    else
      echo "  ✔ expected: kernel thread $p refused by cgroup — the cap bounds userspace only"
    fi
  fi
done

###############################################################################
hdr "VERDICT"
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] \
  && echo "  ➜ in-kernel design viable WITH the mount-ns recipe. dsx.yml should ship this." \
  || echo "  ➜ failures remain — read the inner log above; ganesha fallback still open."
