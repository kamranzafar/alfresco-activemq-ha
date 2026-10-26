# Highly available ActiveMQ for Alfresco Content Services 25.2 on Kubernetes

This is a Helm chart for an **active/standby ActiveMQ Classic 6.2** broker for ACS. The chart uses Alfresco's own image, `alfresco/alfresco-activemq:6.2.6-jre17-rockylinux8`, and replaces the bundled single-pod evaluation ActiveMQ in the ACS Helm chart.

> **Broker version:** the ACS 25.2 supported-platforms matrix lists ActiveMQ 5.18; Alfresco moved to ActiveMQ 6.x in ACS 26.1. Check the matrix for your ACS release before running 6.2 in production. To stay on 5.18, set `image.tag=5.18-jre17-rockylinux8`; the chart works with both.

```
 Alfresco repo ─┐
 Transform Svc ─┤  failover:(nio://<release>-alfresco-activemq-ha.<ns>.svc:61616)?timeout=3000&jms.useCompression=true
 Search Ent.   ─┤                         │
 Sync / Audit  ─┘                Service (routes to master only)
                                          │
                StatefulSet: pod-0 [1/1 MASTER]   pod-1 [0/1 STANDBY]
                                   └──── shared store ────┘
                         RWX volume (KahaDB + file lock)  or  HA database (JDBC + lease lock)
```

### Why one active/standby pair, not a network of brokers

Alfresco's broker traffic is moderate. It covers the transform request/reply flow and the repository event stream that feeds Search Enterprise live indexing. What matters for that traffic is ordering and at-least-once delivery, not scale-out.

A single active broker gives every destination one ordered path. A network of brokers adds forwarding paths that can reorder or duplicate events. Reordered or duplicated events on the event stream lead to index drift, and the bridges add little capacity Alfresco would use.

## How it works

**Readiness means master.** Both pods mount the same store. The pod holding the lock is master and opens its ports. The standby blocks until the lock frees and never listens, so a TCP readiness probe makes only the master Ready. The client Service therefore always points at the master. **Seeing `0/1` on the standby is correct.**

**Failover.** When the master dies, its lock is released and the standby takes over the same store, with every persisted message intact. It becomes Ready and the Service flips to it. Alfresco's failover transport reconnects to the same DNS name.

**Kubernetes settings that differ from the defaults:**
- `podManagementPolicy: Parallel`. With the default, the StatefulSet could block pod creation forever behind an unready standby.
- `updateStrategy: OnDelete`. A rolling update would stall waiting for the standby to become Ready. Use `scripts/rolling-restart.sh` instead.
- No liveness probe. A TCP liveness check would kill the healthy standby.
- Hard anti-affinity and zone spread instead of a PodDisruptionBudget. With only one Ready pod, any PDB would block every node drain.

**Image details the chart accounts for:** the image runs as uid 33031 / gid 1000. Its entrypoint writes admin credentials into `conf/` from `ACTIVEMQ_ADMIN_LOGIN` and `ACTIVEMQ_ADMIN_PASSWORD`, which is why only `activemq.xml` is mounted, via `subPath`. The entrypoint also appends to `ACTIVEMQ_OPTS`, so the chart sets that variable explicitly; otherwise ActiveMQ's heap and `login.config` defaults would be dropped.

## Try it locally first

`local/` sets up a kind cluster for you, either single node or 3 workers with a shared store, and installs the chart. It includes a failover smoke test. See [local/README.md](local/README.md):

```bash
cd local && ./up.sh && ./failover-smoke.sh
```

## Prerequisites

You need one of the following for the shared store.

| Store | Requirement |
|---|---|
| `sharedVolume` (default) | A **ReadWriteMany** volume whose storage supports POSIX `fcntl` locks across nodes: AWS EFS, Azure Files **NFS**, GCP Filestore **mounted with NFSv4.1**, CephFS or NFSv4. The lock is the only thing preventing two masters, so EBS, Azure Disk, PD and Azure Files SMB **will not work**. |
| `jdbc` | An HA database (for example RDS/Aurora PostgreSQL) and an image that contains the JDBC driver. See below. |

On EKS, `examples/efs-storageclass.yaml` creates EFS access points that enforce the broker's uid and gid. With it, permissions work without the root init container, so set `fixPermissions: false`.

On GKE, use `examples/gke-filestore-storageclass.yaml` with `examples/values-gke.yaml`. GKE's built-in Filestore classes (`standard-rwx`, `enterprise-rwx` and so on) mount NFSv3. With NFSv3, the client holds the lock, so a master whose node is deleted keeps the lock, and the standby never takes over. The example class uses the Regional tier with NFSv4.1, whose server-side lease releases the lock. It needs GKE 1.33.4-gke.1172000 or later and at least 1 TiB.

## Install

```bash
kubectl create namespace amq

helm install amq ./chart/alfresco-activemq-ha -n amq \
  --set auth.adminPassword='<admin-pw>' \
  --set auth.brokerPassword='<alfresco-pw>' \
  --set persistence.sharedVolume.storageClass=efs-amq \
  --set alfrescoConnection.namespace=alfresco      # where ACS runs

kubectl -n amq get pods -w        # expect one 1/1 and one 0/1
helm test amq -n amq              # persistent produce/consume round trip through the Service
scripts/status.sh amq amq
```

For production, use `examples/values-production.yaml`. It takes credentials from an existing Secret, uses EFS, sets sizing and enables a NetworkPolicy.

## Connect Alfresco 25.2

With `alfrescoConnection.enabled=true` (the default), the chart creates a Secret and a ConfigMap named `alfresco-message-broker` in the ACS namespace. The Secret holds `BROKER_URL`, `BROKER_USERNAME` and `BROKER_PASSWORD`. Then disable the bundled broker in your ACS values and point each component at this one. `examples/acs-values-external-broker.yaml` has the full values:

```yaml
activemq:
  enabled: false
messageBroker:
  url: failover:(nio://amq-alfresco-activemq-ha.amq.svc.cluster.local:61616)?timeout=3000&jms.useCompression=true
  existingSecretName: alfresco-message-broker
alfresco-repository:
  configuration:
    messageBroker:
      existingSecret:
        name: alfresco-message-broker
alfresco-transform-service:
  messageBroker:
    existingSecret:
      name: alfresco-message-broker
# ...and the same messageBroker.existingSecret.name block for
# alfresco-search-enterprise, alfresco-sync-service, alfresco-audit-storage,
# alfresco-ai-transformer and alfresco-connector-cic
```

```bash
helm install acs alfresco/alfresco-content-services --version 10.0.0 -n alfresco \
  -f examples/acs-values-external-broker.yaml       # chart 10.0.0 ships ACS 25.2
```

**Every broker-connected sub-chart must be listed.** The ACS chart puts `messageBroker.url` into its `alfresco-infrastructure` ConfigMap, and all sub-charts read the URL from there, so the URL is set once. Credentials work differently. When `messageBroker.existingSecretName` is set, the ACS chart stops creating its own broker secret, `acs-alfresco-cs-brokersecret`, but each sub-chart still points at that name by default. A sub-chart you leave out references a secret that doesn't exist, and its pods don't start. Rendering chart 10.0.0 with the example file gives 28 credential references, all to `alfresco-message-broker`.

The key paths come from the ACS chart's `values.yaml`. The acs-deployment page "Helm Deployment with external infrastructure" uses different keys for some sub-charts, which those sub-charts don't read. For another chart version, check the keys with `helm show values alfresco/alfresco-content-services --version <x> | grep -A6 messageBroker`.

If you set `auth.existingSecret.name` (as the production and GKE examples do), this chart doesn't create the ACS-namespace secret. Create `alfresco-message-broker` there yourself, with `BROKER_USERNAME` and `BROKER_PASSWORD`.

**About `timeout=3000`.** This is Alfresco's default. A send blocked by a broker outage fails after 3 seconds instead of waiting. A failover caused by a pod or process dying takes about 2 to 5 seconds, so expect a few logged send errors during it. Node or network failures on NFS storage take longer, because the old master's lock is held until the NFS lease expires. Measure your failover time, for example by deleting the master pod while ACS is under load. Then decide whether to raise `timeout` or accept retries.

### Without the ACS Helm chart: `alfresco-global.properties`

For a repository installed on VMs, from the distribution zip, or with Docker Compose, set the broker in `alfresco-global.properties` on **every** repository node:

```properties
# List every broker; the failover transport connects to whichever is master.
# randomize=false tries them in order instead of picking one at random.
messaging.broker.url=failover:(nio://amq1:61616,nio://amq2:61616)?randomize=false&timeout=3000&jms.useCompression=true
messaging.broker.username=alfresco
messaging.broker.password=<alfresco-pw>
```

On Kubernetes with a single Service in front of the master, the URL needs only that Service: `failover:(nio://amq-alfresco-activemq-ha.amq.svc.cluster.local:61616)?timeout=3000&jms.useCompression=true`.

- **What they are:** these are the repository's Messaging subsystem properties. The ACS Helm chart sets the same three as `-Dmessaging.broker.*` JVM options from `BROKER_URL`, `BROKER_USERNAME` and `BROKER_PASSWORD`. In Docker, you can pass them the same way in `JAVA_OPTS`.
- **Credentials are required:** the broker rejects anonymous connections, and Alfresco's defaults for username and password are empty.
- **Messaging stays enabled:** keep `messaging.subsystem.autoStart=true`, which is the default.
- **Other services** (Transform Service, Search Enterprise, Sync Service and the rest) don't read `alfresco-global.properties`. Give each one the same failover URL and credentials in its own configuration.

## Day-2 operations

**Config or image change:** run `helm upgrade`, then `scripts/rolling-restart.sh amq amq`. Pods are not restarted by the upgrade itself. The script restarts the standby first, then hands over from the master, so the change costs one failover.

**Failover drill:** run `kubectl -n amq delete pod <master> --grace-period=0 --force`, then `scripts/status.sh amq amq`.

**Web console:** run `kubectl -n amq port-forward svc/amq-alfresco-activemq-ha 8161` and log in as the admin user.

**Dead letters:** failed messages land in `DLQ.<queue>`, because `broker.deadLetter.individual` is on. Monitor these queues.

**Uninstall:** the chart-created PVC has `helm.sh/resource-policy: keep`, so stored messages survive `helm uninstall`.

## JDBC mode (no shared file system)

Build an image with the PostgreSQL driver. 42.7.5 is the driver version in the ACS 25.2 matrix. Commons DBCP2 already ships in ActiveMQ's `lib/optional`.

```dockerfile
FROM alfresco/alfresco-activemq:6.2.6-jre17-rockylinux8
ADD --chown=33031:1000 --chmod=644 \
  https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.5/postgresql-42.7.5.jar \
  /opt/activemq/lib/optional/
```

```bash
helm install amq ./chart/alfresco-activemq-ha -n amq \
  --set image.repository=<registry>/alfresco-activemq-pg --set image.tag=6.2.6 \
  --set persistence.mode=jdbc \
  --set persistence.jdbc.url=jdbc:postgresql://<db-host>:5432/activemq \
  --set persistence.jdbc.existingSecret.name=amq-db      # keys JDBC_USERNAME / JDBC_PASSWORD
```

Things to know about JDBC mode:
- **Database:** use a dedicated database for the broker, not the Alfresco repository database. Tables are created on first start.
- **Failover time:** about one lease (`lockAcquireSleepInterval`, 10 seconds by default).
- **Clocks:** the lease locker depends on node clocks being in sync (NTP).
- **Throughput:** lower than KahaDB, which is usually fine at Alfresco's message volumes.

## Without Kubernetes: Docker image

`standalone/activemq.xml` is the same broker setup for plain Docker or VMs, and `standalone/Dockerfile` bakes it into Alfresco's 6.2.6 image:

```bash
docker build -t alfresco-activemq-ha:6.2.6 standalone
# on every broker host, with the same shared directory (POSIX locks across hosts) at /mnt/amq-shared:
docker run -d --name amq1 -p 61616:61616 -v /mnt/amq-shared:/mnt/amq-shared \
  -e ADMIN_PASSWORD=<admin-pw> -e ALFRESCO_PASSWORD=<alfresco-pw> \
  -e ACTIVEMQ_ADMIN_LOGIN=admin -e ACTIVEMQ_ADMIN_PASSWORD=<admin-pw> \
  alfresco-activemq-ha:6.2.6
```

The first broker to lock `/mnt/amq-shared/kahadb` is master; the others wait without listening. Point Alfresco at all hosts: `failover:(nio://amq1:61616,nio://amq2:61616)?randomize=false&timeout=3000&jms.useCompression=true`. The broker won't start without both passwords.

To try it on one machine, `standalone/docker-compose.yaml` runs two brokers sharing a named volume (passwords default to `admin`/`alfresco`):

```bash
docker compose -f standalone/docker-compose.yaml up -d --build
docker compose -f standalone/docker-compose.yaml kill amq1    # or amq2, whichever is master
```

Connect with `failover:(tcp://localhost:61616,tcp://localhost:61617)?randomize=false`.

## On AWS: consider Amazon MQ instead

Amazon MQ for ActiveMQ in active/standby across availability zones gives you the same architecture, with storage, patching and failover managed by AWS. If you go that way, skip this chart. Set `messageBroker.url` to `failover:(ssl://<broker-1>:61617,ssl://<broker-2>:61617)?randomize=false&timeout=3000` and keep the rest of the ACS values above. Pick the Amazon MQ engine version that matches the broker version supported for your ACS release.

## Values reference (main ones)

| Key | Default | Notes |
|---|---|---|
| `image.tag` | `6.2.6-jre17-rockylinux8` | `5.18-jre17-rockylinux8` also works |
| `replicaCount` | `2` | `1` means no HA |
| `persistence.mode` | `sharedVolume` | or `jdbc` |
| `persistence.sharedVolume.storageClass` | `""` | Must be RWX with POSIX locks |
| `persistence.sharedVolume.fixPermissions` | `true` | Root init container; set `false` on EFS access points or under the PSA "restricted" profile |
| `auth.existingSecret.name` | `""` | Otherwise `auth.adminPassword` and `auth.brokerPassword` are required |
| `broker.transports.stomp.enabled` | `false` | Turn on to run the earlier Python test suite in-cluster |
| `alfrescoConnection.namespace` | release namespace | Where the ACS connection Secret and ConfigMap are created |
| `service.type` / `service.nodePorts` | `ClusterIP` / unset | Fixed NodePorts, for example for kind port mappings |
| `networkPolicy.enabled` | `false` | Restrict to the ACS namespace in production |
| `antiAffinity` / `zoneSpread` | `hard` / `true` | Keep master and standby apart |

## Production checklist

- Credentials come from an existing Secret managed by External Secrets or similar, and the ACS-namespace secret is created the same way.
- The image tag is pinned, and the store size matches `broker.storeUsageLimit` with headroom.
- A NetworkPolicy limits access to the ACS namespace.
- Monitoring covers DLQs, queue depth on transform request queues, and the store-usage percentage via JMX or Jolokia.
- A failover drill under load has been run, with transform and indexing backlogs confirmed to drain afterwards.
- Backup and restore of the store, whether EFS backups or database snapshots, is tested.
