# NFS load generator. Deliberately tiny: fio is the load engine, the entrypoint
# wraps it in a repeating cycle so a single `docker run` produces sustained,
# observable NFS traffic for a full ~2-hour test window.
#
# Built ON the client node by the Ansible workload role (no registry needed):
#   docker build -t nfs-harness-workload .
FROM alpine:3.20

RUN apk add --no-cache fio coreutils

COPY run-load.sh /usr/local/bin/run-load.sh
RUN chmod +x /usr/local/bin/run-load.sh

# Where the NFS share is bind-mounted into the container at run time.
ENV TARGET_DIR=/data \
    RW=randrw \
    BLOCK_SIZE=64k \
    FILE_SIZE=512M \
    NUMJOBS=4 \
    RUNTIME=120 \
    LOOP=true

ENTRYPOINT ["/usr/local/bin/run-load.sh"]
