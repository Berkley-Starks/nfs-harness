# Workload container — NFS load generator

A tiny Alpine + `fio` image that drives sustained, observable I/O against the
mounted NFS share. The Ansible `workload` role builds it **on each client**
(no registry required) and runs it with the NFS mount bind-mounted at `/data`.

## Knobs (env vars)

| var          | default   | meaning                                   |
|--------------|-----------|-------------------------------------------|
| `TARGET_DIR` | `/data`   | mount point of the NFS share in-container |
| `RW`         | `randrw`  | fio access pattern (`read`/`write`/`randrw`/…) |
| `BLOCK_SIZE` | `64k`     | I/O block size                            |
| `FILE_SIZE`  | `512M`    | working-set size per job                  |
| `NUMJOBS`    | `4`       | concurrent fio jobs                       |
| `RUNTIME`    | `120`     | seconds per pass                          |
| `LOOP`       | `true`    | repeat passes for the whole test window   |

Each client writes under `/data/load/<hostname>/` so the fleet doesn't collide.

## Run by hand (on a client)

```bash
docker build -t nfs-harness-workload /opt/nfs-harness/workload
docker run --rm -v /mnt/nfs:/data -e RW=write -e RUNTIME=60 nfs-harness-workload
```
