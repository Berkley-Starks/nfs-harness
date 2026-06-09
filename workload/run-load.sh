#!/bin/sh
###############################################################################
# NFS load generator entrypoint.
#
# Drives fio against a directory that IS the mounted NFS share. Each pass is a
# bounded fio run; with LOOP=true it repeats so the fleet keeps a steady,
# scrape-able load on the backend across the whole test window. All knobs come
# from env (set in the Dockerfile, overridable at `docker run -e`).
#
# Per-host isolation: each client writes under its own subdir so N clients
# hammering one share don't collide on the same files.
###############################################################################
set -eu

TARGET_DIR="${TARGET_DIR:-/data}"
RW="${RW:-randrw}"
BLOCK_SIZE="${BLOCK_SIZE:-64k}"
FILE_SIZE="${FILE_SIZE:-512M}"
NUMJOBS="${NUMJOBS:-4}"
RUNTIME="${RUNTIME:-120}"
LOOP="${LOOP:-true}"

HOST="$(hostname)"
WORKDIR="${TARGET_DIR}/load/${HOST}"
mkdir -p "$WORKDIR"

echo "nfs-harness workload starting"
echo "  target=${WORKDIR} rw=${RW} bs=${BLOCK_SIZE} size=${FILE_SIZE} jobs=${NUMJOBS} runtime=${RUNTIME}s loop=${LOOP}"

run_once() {
  fio \
    --name=nfs_harness \
    --directory="$WORKDIR" \
    --rw="$RW" \
    --bs="$BLOCK_SIZE" \
    --size="$FILE_SIZE" \
    --numjobs="$NUMJOBS" \
    --iodepth=16 \
    --ioengine=psync \
    --runtime="$RUNTIME" \
    --time_based \
    --direct=0 \
    --group_reporting \
    --output-format=normal
}

while : ; do
  run_once || echo "fio pass exited non-zero; continuing"
  [ "$LOOP" = "true" ] || break
  echo "--- pass complete, looping ---"
done

echo "workload finished (LOOP=false)"
