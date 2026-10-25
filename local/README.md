# Running the chart locally

You need `docker`, `kind`, `kubectl` and `helm`. The cluster needs about 3 GB of free memory for the multi-node setup.

On a laptop, the chart's one hard requirement is a shared volume with working file locks across pods. Local clusters don't offer ReadWriteMany storage, so there are two ways around it:

| Mode | What it gives you | Storage trick |
|---|---|---|
| `./up.sh` (single node) | Pod failover, rolling restarts, `helm test`. Works on Linux, macOS and Windows. | One node, so an ordinary RWO volume can be mounted by both pods. "Read-write once" means one node, not one pod. Both pods share the kernel, so the lock is real. |
| `./up.sh multi` (3 workers) | Hard anti-affinity, zone spread, and **node-failure** drills, just like production. | Every kind worker mounts the same host directory, and a static RWX PersistentVolume points at it. All kind nodes share the host kernel, so the lock works across nodes. |

## Quick start

```bash
cd local
./up.sh                      # or: ./up.sh multi
../scripts/status.sh amq amq
./failover-smoke.sh          # kill the master pod mid-stream; PASS = nothing lost
./failover-smoke.sh node     # multi mode only: stop the master's node container
./down.sh
```

`up.sh` creates the cluster, installs the chart with `values-local.yaml` (plus `values-local-multinode.yaml` in multi mode), waits for a master and runs `helm test`.

From your machine, use these addresses:

| What | Address |
|---|---|
| OpenWire | `tcp://localhost:61616`, with user `alfresco`/`alfresco` or admin `admin`/`admin` |
| STOMP | `localhost:61613` |
| Console | http://localhost:8161 |

These go through a fixed NodePort mapped by kind, so they **keep working across failovers**. `kubectl port-forward` would not: it pins to one pod and dies with it.

## Things worth trying

**Watch a failover:**

```bash
kubectl -n amq get pods -w &
kubectl -n amq delete pod <master> --force --grace-period=0
```

The standby takes over within a couple of seconds and turns 1/1.

**Run a rolling upgrade:** change something in `values-local.yaml` (for example `broker.storeUsageLimit`), then:

```bash
helm upgrade amq ../chart/alfresco-activemq-ha -n amq -f values-local.yaml
../scripts/rolling-restart.sh amq amq
```

**Compare node failure with pod failure (multi mode):** run `./failover-smoke.sh node`. The new master is up within seconds, but the dead master's endpoint stays in the Service until Kubernetes marks its node NotReady, which takes about 40 seconds by default. During that window some connection attempts go to a dead IP and time out instead of being refused. Alfresco's `timeout=3000` sends will log errors in that window. The same thing happens in production on a real node loss, and this is a safe place to see it.

**Use 3 brokers:** this is already set in multi mode (`replicaCount: 3`, one per zone label).

**Point the Python test suite at it:** `ResilientClient("A", ...)` finds the master through `localhost:61613`. The suite's kill and start steps use `docker kill` on Compose container names, though, so only the non-chaos checks apply unchanged.

## Other local Kubernetes options

**Docker Desktop Kubernetes (single node):**

```bash
helm install amq ../chart/alfresco-activemq-ha -n amq --create-namespace \
  -f values-local.yaml --set service.type=LoadBalancer
```

The LoadBalancer is published on `localhost:61616`, `localhost:61613` and `localhost:8161`.

**minikube (single node):** run `helm install ... -f values-local.yaml`, then use `minikube service amq-alfresco-activemq-ha -n amq --url` to get the reachable ports. Allocate at least 4 GB of memory to minikube.

**k3d or Rancher Desktop:** these work like kind single-node, because the default `local-path` storage is RWO on one node.

## Caveats

- **Multi mode on macOS and Windows:** the shared directory is a Docker Desktop file-sharing mount. The file lock usually works across containers there, but it is not guaranteed the way it is on a Linux host. **Check that only one pod is ever 1/1.** If you ever see two Ready brokers, use single-node mode on that machine.
- **What local runs prove:** they check behaviour, not storage. Real failover times on EFS or NFS are longer for node loss, because the NFS lock lease must expire first. Repeat the drills on the target platform.
- **Docker Hub limits:** if the image pull is rate-limited, run `LOAD_IMAGE=1 ./up.sh` to pull once on the host and load the image into kind.
