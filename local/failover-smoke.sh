#!/usr/bin/env bash
# In-cluster failover smoke test using the image's own JMS client:
# a consumer and a producer (persistent, failover URL) run as Jobs while the
# master pod is force-deleted. PASS = the consumer received every message.
# (Counts only. For duplicate/ordering analysis use the Python suite.)
set -euo pipefail
NS=${NS:-amq}; REL=${REL:-amq}; N=${N:-3000}; SLEEP_MS=${SLEEP_MS:-10}
MODE=${1:-pod}      # pod: force-delete the master pod | node: stop the master's kind node container
img=$(kubectl -n "$NS" get sts -l "app.kubernetes.io/instance=$REL" -o jsonpath='{.items[0].spec.template.spec.containers[0].image}')
svc=$(kubectl -n "$NS" get svc -l "app.kubernetes.io/instance=$REL,amq.role=client" -o jsonpath='{.items[0].metadata.name}')
secret=$(kubectl -n "$NS" get sts -l "app.kubernetes.io/instance=$REL" \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].env[?(@.name=="BROKER_PASSWORD")].valueFrom.secretKeyRef.name}')
master() { kubectl -n "$NS" get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].targetRef.name}'; }
q="queue://smoke.$(date +%s)"
url="failover:(tcp://$svc:61616)?initialReconnectDelay=500&maxReconnectDelay=2000"

job() {  # name, activemq sub-command and args
  local name=$1; shift
  kubectl -n "$NS" delete job "$name" --ignore-not-found >/dev/null
  cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: $name }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: c
          image: $img
          command: ["/bin/bash", "-ec"]
          # bin/activemq evals its args, so the URL needs an extra layer of quotes
          args: ['cd /opt/activemq && bin/activemq $* --brokerUrl "''$url''" --user "\$U" --password "\$P" --destination "$q"']
          env:
            - { name: U, valueFrom: { secretKeyRef: { name: $secret, key: BROKER_USERNAME } } }
            - { name: P, valueFrom: { secretKeyRef: { name: $secret, key: BROKER_PASSWORD } } }
YAML
}

m=$(master); echo "master: $m   queue: $q   messages: $N"
job smoke-consumer consumer --messageCount "$N"
job smoke-producer producer --messageCount "$N" --sleep "$SLEEP_MS" --persistent true
sleep $(( N * SLEEP_MS / 3000 + 5 ))     # roughly a third of the way through

if [[ $MODE == node ]]; then
  node=$(kubectl -n "$NS" get pod "$m" -o jsonpath='{.spec.nodeName}')
  echo "stopping kind node $node (simulated node failure)"
  docker stop "$node" >/dev/null
else
  echo "force-deleting master pod $m"
  kubectl -n "$NS" delete pod "$m" --grace-period=0 --force >/dev/null 2>&1
fi
t0=$SECONDS
until n=$(master) && [[ -n $n && $n != "$m" ]]; do sleep 1; done
echo "new master: $n (Service switched after ~$((SECONDS - t0))s)"

if kubectl -n "$NS" wait --for=condition=complete job/smoke-consumer --timeout=300s >/dev/null 2>&1; then
  echo "PASS: consumer received all $N messages across the failover"; rc=0
else
  echo "FAIL: consumer did not receive $N messages within 5 min"; rc=1
  kubectl -n "$NS" logs job/smoke-consumer --tail=20 || true
fi
[[ $MODE == node ]] && { docker start "$node" >/dev/null; echo "restarted node $node"; }
kubectl -n "$NS" delete job smoke-consumer smoke-producer --ignore-not-found >/dev/null
exit $rc
