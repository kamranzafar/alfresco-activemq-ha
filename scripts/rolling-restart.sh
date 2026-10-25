#!/usr/bin/env bash
# Safe rollout for the alfresco-activemq-ha StatefulSet (updateStrategy: OnDelete).
#   1. restart the standby pod(s): they come back with the new config/image and wait for the lock
#   2. delete the master: it stops cleanly, releases the lock, an updated standby takes over
#   3. the old master pod restarts as the new standby
# Alfresco sees one failover (a few seconds) per run.
#
# Usage: scripts/rolling-restart.sh <release> [namespace]
set -euo pipefail
REL=${1:?usage: $0 <release> [namespace]}
NS=${2:-default}
WARMUP=${WARMUP:-30}     # secs for a restarted standby JVM to boot and start polling the lock

sel="app.kubernetes.io/instance=$REL,app.kubernetes.io/name=alfresco-activemq-ha"
svc=$(kubectl -n "$NS" get svc -l "app.kubernetes.io/instance=$REL,amq.role=client" -o jsonpath='{.items[0].metadata.name}')
master() { kubectl -n "$NS" get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].targetRef.name}'; }
wait_running() {
  for _ in $(seq 1 150); do
    [[ $(kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true) == Running ]] && return 0
    sleep 2
  done
  echo "timeout waiting for $1 to run"; exit 1
}

m=$(master)
[[ -n $m ]] || { echo "no master behind service $svc; aborting"; exit 1; }
echo "service: $svc   master: $m"

for p in $(kubectl -n "$NS" get pods -l "$sel" -o jsonpath='{.items[*].metadata.name}'); do
  [[ $p == "$m" ]] && continue
  echo ">> restarting standby $p"
  kubectl -n "$NS" delete pod "$p" --wait=true
  wait_running "$p"
  sleep "$WARMUP"
done

echo ">> handing over from master $m"
kubectl -n "$NS" delete pod "$m" --wait=false
n=""
for _ in $(seq 1 90); do
  n=$(master); [[ -n $n && $n != "$m" ]] && break; sleep 1
done
[[ -n $n && $n != "$m" ]] || { echo "no new master after 90s; check pod logs"; exit 1; }
echo "new master: $n"
wait_running "$m"
echo ">> done; $m is now the standby"
