#!/bin/bash
###############################################################################
# dsx-portal.sh — DSX-style NFSv3 protocol portal, from raw kernel primitives.
#
# Models the Hammerspace DSX protocol-portal containerization: the HOST kernel
# keeps serving NFSv4.2 on its own :2049, while this script stands up a second,
# independent in-kernel NFS server — NFSv3-ONLY, also on :2049 — inside its own
# network namespace, with its own mount-namespace view of the NFS state dirs and
# a cgroup v2 cap on its control plane. No Docker, no runc: ip-netns, unshare,
# veth, and the nfsd control filesystem.
#
# The mechanism (proven in docs/dsx-derisk/, 7/7 on AL2023 kernel 6.18):
#   * a netns has its OWN port space -> no :2049 collision with the host;
#   * each `mount -t nfsd` binds to the NETWORK NAMESPACE of the mounting
#     process -> a fresh mount inside the ns gives rpc.nfsd a control handle to
#     a SECOND kernel NFS server, scoped to the ns;
#   * `ip netns exec` switches only the net ns — the portal also needs a private
#     MOUNT ns (tmpfs /run, private /var/lib/nfs, its own /etc/exports) so its
#     rpcbind/etab don't collide with the host's.
#
# Usage: dsx-portal.sh start|stop|status|restart
#
# Knobs (env, all defaulted):
#   DSX_NS            namespace name           (dsx-v3)
#   DSX_HOST_IP       host end of the veth     (10.200.0.1)
#   DSX_NS_IP         portal end of the veth   (10.200.0.2)  <- clients mount this
#   DSX_EXPORT_DIR    directory the portal exports (/srv/nfs/dsx-v3)
#   DSX_EXPORT_CIDR   who may mount the v3 export  (10.0.0.0/8)
#   DSX_NFSD_THREADS  portal nfsd thread count (4)
#   DSX_CPU_MAX       cgroup cpu.max           ("50000 100000" = 0.5 CPU)
#   DSX_MEM_MAX       cgroup memory.max bytes  (268435456 = 256 MiB)
#
# Designed to be wrapped by a oneshot systemd unit (ExecStart=... start,
# ExecStop=... stop, RemainAfterExit=yes) and shipped by roles/nfs_server.
###############################################################################
set -uo pipefail

NS="${DSX_NS:-dsx-v3}"
HOST_IP="${DSX_HOST_IP:-10.200.0.1}"
NS_IP="${DSX_NS_IP:-10.200.0.2}"
EXPORT_DIR="${DSX_EXPORT_DIR:-/srv/nfs/dsx-v3}"
EXPORT_CIDR="${DSX_EXPORT_CIDR:-10.0.0.0/8}"
NFSD_THREADS="${DSX_NFSD_THREADS:-4}"
CPU_MAX="${DSX_CPU_MAX:-50000 100000}"
MEM_MAX="${DSX_MEM_MAX:-268435456}"

VETH_H="veth-${NS}-h"
VETH_C="veth-${NS}-c"
CG="/sys/fs/cgroup/${NS}"
STATE="/var/lib/dsx/${NS}"          # portal-private exports file + helper script

say()  { echo "==> $*"; }
err()  { echo "xx  $*" >&2; }

require_root() { [ "$(id -u)" = "0" ] || { err "must run as root"; exit 1; }; }

portal_running() {
  # The portal is "running" iff its netns exists AND something listens on :2049
  # inside it (kernel nfsd sockets — they have no owning pid, so check ports).
  ip netns list 2>/dev/null | grep -qw "$NS" || return 1
  ip netns exec "$NS" ss -tln "sport = :2049" 2>/dev/null | grep -q 2049
}

#------------------------------------------------------------------------------
# start
#------------------------------------------------------------------------------
do_start() {
  require_root

  if portal_running; then
    say "portal '$NS' already running (idempotent start)"; return 0
  fi
  # self-heal a half-torn-down state before building
  ip netns list 2>/dev/null | grep -qw "$NS" && do_stop quiet

  say "creating portal state + export dir"
  mkdir -p "$STATE" "$EXPORT_DIR"
  chmod 1777 "$EXPORT_DIR"
  # The portal's OWN export table — bind-mounted over /etc/exports inside the
  # portal's mount ns. insecure: NFSv3 clients through NAT/forwarding may use
  # ports >1023; the export is still CIDR-scoped.
  #
  # no_root_squash — deliberate, and a protocol-fidelity finding (strace-proven
  # on AL2023 6.18): with root_squash, a ROOT writer's open(O_CREAT|O_WRONLY)
  # over NFSv3 EACCESes — CREATE succeeds as nobody, then the access check pits
  # local uid 0 against the nobody-owned 0644 file (no CAP_DAC_OVERRIDE over
  # NFS) and denies the open. NFSv4.2's atomic server-side OPEN resolves
  # create+access as the squashed identity, which is why the harness's main 4.2
  # export runs root_squash with root-fio happily. v3 can't, without aligning
  # writer uids — so the portal models what legacy-v3 fabrics actually run.
  # Override via DSX_EXPORT_OPTS if your v3 writers are non-root.
  local opts="${DSX_EXPORT_OPTS:-rw,sync,no_subtree_check,no_root_squash,insecure}"
  cat > "$STATE/exports" <<EOF
$EXPORT_DIR ${EXPORT_CIDR}($opts)
EOF

  say "creating netns '$NS' + veth ($HOST_IP <-> $NS_IP)"
  ip netns add "$NS"
  ip netns exec "$NS" ip link set lo up
  ip link add "$VETH_H" type veth peer name "$VETH_C"
  ip link set "$VETH_C" netns "$NS"
  ip addr add "${HOST_IP}/24" dev "$VETH_H"
  ip link set "$VETH_H" up
  ip netns exec "$NS" ip addr add "${NS_IP}/24" dev "$VETH_C"
  ip netns exec "$NS" ip link set "$VETH_C" up
  ip netns exec "$NS" ip route add default via "$HOST_IP" 2>/dev/null || true

  # Forwarding so off-box clients can reach the portal IP through the host
  # (pairs with a VPC route to this instance + src/dst-check off, wired by TF).
  sysctl -qw net.ipv4.ip_forward=1
  sysctl -qw "net.ipv4.conf.${VETH_H}.forwarding=1" 2>/dev/null || true

  say "writing portal-inner helper (runs in netns + PRIVATE mount ns)"
  cat > "$STATE/portal-inner.sh" <<'INNER'
#!/bin/bash
# Runs via: ip netns exec <ns> unshare -m <this script> <state-dir> <threads>
# Everything mounted here is invisible to the host — this is the "container's"
# private filesystem view, namespaced state only (no rootfs pivot needed).
set -euo pipefail
STATE="$1"; THREADS="$2"
mount --make-rprivate /
mount -t tmpfs tmpfs /run                          # private rpcbind state
mkdir -p /run/rpcbind
cp -a /var/lib/nfs /run/nfs-private                # private etab/rmtab seed
mount --bind /run/nfs-private /var/lib/nfs
mount --bind "$STATE/exports" /etc/exports         # the portal's export table
# THE key line: a fresh nfsd control-fs mount binds to THIS netns, giving
# rpc.nfsd a handle to a second, namespace-scoped kernel NFS server.
mount -t nfsd nfsd /proc/fs/nfsd
rpcbind                                            # portmapper (:111) — v3 needs it
exportfs -ra
rpc.nfsd --nfs-version 3 --no-nfs-version 4 "$THREADS"   # v3-ONLY server
rpc.mountd --no-nfs-version 4                      # MNT protocol (daemonizes)
# rpcbind + rpc.mountd daemonize INSIDE this mount ns and keep it alive;
# no holder process is needed.
echo "portal services up: $(ss -tln 'sport = :2049' | grep -c 2049) x :2049 listener(s)"
INNER
  chmod +x "$STATE/portal-inner.sh"

  say "starting portal services (v3-only nfsd, $NFSD_THREADS threads)"
  if ! ip netns exec "$NS" unshare -m "$STATE/portal-inner.sh" "$STATE" "$NFSD_THREADS"; then
    err "portal services failed to start — tearing back down"
    do_stop quiet
    exit 1
  fi

  say "applying cgroup v2 cap (cpu.max='$CPU_MAX', memory.max=$MEM_MAX)"
  grep -q cpu /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null \
    || echo "+cpu +memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
  mkdir -p "$CG"
  echo "$CPU_MAX" > "$CG/cpu.max"
  echo "$MEM_MAX" > "$CG/memory.max"
  local confined=0
  for p in $(ip netns pids "$NS" 2>/dev/null); do
    echo "$p" > "$CG/cgroup.procs" 2>/dev/null && confined=$((confined+1))
  done
  say "confined $confined portal pid(s) into $CG"
  # NOTE (kernel 6.18 finding, docs/dsx-derisk/): [nfsd] kthreads are also
  # accepted into the cgroup on modern kernels; whether cpu.max throttles them
  # under load is measured separately. The userspace control plane above is
  # the part the cap is guaranteed to bind.

  # Readiness probe: listening != usable. Kernel nfsd authorizes each new client
  # via an upcall to rpc.mountd's auth cache; a COLD cache can bounce the first
  # I/O with EACCES even though the mount itself succeeded. Probe-mount and
  # touch in a retry loop so `start` only returns when the portal serves I/O —
  # which is what systemd/Ansible need a oneshot start to mean.
  say "waiting for portal readiness (auth cache warm-up)"
  local probe_mnt; probe_mnt="$(mktemp -d /tmp/dsx-probe.XXXXXX)"
  local ready=""
  for _i in 1 2 3 4 5 6; do
    if mount -t nfs -o vers=3,proto=tcp,mountproto=tcp,timeo=20,retrans=1 \
         "$NS_IP:$EXPORT_DIR" "$probe_mnt" 2>/dev/null; then
      # Write DATA, not just touch: a create-only probe passed while root
      # O_CREAT-writes were EACCESing (the v3 root_squash papercut above).
      # "Ready" must mean a root writer can create AND write.
      if echo dsx-ready > "$probe_mnt/.dsx-ready" 2>/dev/null \
         && [ "$(cat "$probe_mnt/.dsx-ready" 2>/dev/null)" = "dsx-ready" ]; then
        rm -f "$probe_mnt/.dsx-ready"; ready=yes
      fi
      umount "$probe_mnt" 2>/dev/null
    fi
    [ -n "$ready" ] && break
    sleep 2
  done
  rmdir "$probe_mnt" 2>/dev/null
  if [ -n "$ready" ]; then
    say "portal READY (v3 I/O verified)"
  else
    err "portal listening but not serving I/O after retries — leaving up for debug"
    do_status; exit 1
  fi

  do_status
}

#------------------------------------------------------------------------------
# stop
#------------------------------------------------------------------------------
do_stop() {
  require_root
  local quiet="${1:-}"

  if ip netns list 2>/dev/null | grep -qw "$NS"; then
    # Stop the KERNEL server first: killing userspace pids does not stop kernel
    # nfsd threads. A fresh control mount in the same netns reaches the same
    # per-netns server; rpc.nfsd 0 shuts its threads down.
    [ -z "$quiet" ] && say "stopping portal kernel nfsd (rpc.nfsd 0)"
    ip netns exec "$NS" unshare -m bash -c \
      'mount --make-rprivate / && mount -t nfsd nfsd /proc/fs/nfsd && rpc.nfsd 0' 2>/dev/null || true

    [ -z "$quiet" ] && say "killing portal userspace + deleting netns '$NS'"
    ip netns pids "$NS" 2>/dev/null | xargs -r kill 2>/dev/null
    sleep 1
    ip netns pids "$NS" 2>/dev/null | xargs -r kill -9 2>/dev/null
    ip netns del "$NS" 2>/dev/null
  fi
  ip link del "$VETH_H" 2>/dev/null
  # Drain the cgroup before removing it: on modern kernels the portal's nfsd
  # kthreads auto-join alongside the userspace pids, and any straggler makes
  # rmdir fail with EBUSY (the v1 lifecycle leak). Move everything back to the
  # root cgroup, then remove with retries.
  if [ -d "$CG" ]; then
    for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do
      echo "$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null
    done
    for _i in 1 2 3; do rmdir "$CG" 2>/dev/null && break; sleep 1; done
    [ -d "$CG" ] && err "cgroup $CG still busy (will be reaped on reboot)"
  fi
  [ -z "$quiet" ] && say "portal '$NS' stopped (export data in $EXPORT_DIR is preserved)"
  return 0
}

#------------------------------------------------------------------------------
# status
#------------------------------------------------------------------------------
do_status() {
  echo "--- dsx portal status: $NS ---"
  if ! ip netns list 2>/dev/null | grep -qw "$NS"; then
    echo "state: DOWN (no netns)"; return 1
  fi
  if portal_running; then echo "state: RUNNING"; else echo "state: DEGRADED (netns up, no :2049 listener)"; fi
  echo "portal IP: $NS_IP (mount with: -o vers=3 $NS_IP:$EXPORT_DIR)"
  echo "listeners in ns:"
  ip netns exec "$NS" ss -tlnp 2>/dev/null | grep -E ':(111|2049|20048)\s' | sed 's/^/  /' || echo "  (none)"
  if [ -d "$CG" ]; then
    echo "cgroup: cpu.max=$(cat "$CG/cpu.max" 2>/dev/null)  memory.max=$(cat "$CG/memory.max" 2>/dev/null)  procs=$(wc -l < "$CG/cgroup.procs" 2>/dev/null)"
  fi
}

case "${1:-}" in
  start)   do_start ;;
  stop)    do_stop ;;
  status)  do_status ;;
  restart) do_stop quiet; do_start ;;
  *) echo "usage: $0 start|stop|status|restart"; exit 2 ;;
esac
