#!/usr/bin/env bash
# Create a local kind cluster and install the chart.
#   ./up.sh            single node (simplest, works everywhere)
#   ./up.sh multi      control plane + 3 workers sharing one store (node-failure drills)
set -euo pipefail
MODE=${1:-single}
CLUSTER=${CLUSTER:-amq-local}
NS=amq
REL=amq
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="$HERE/../chart/alfresco-activemq-ha"
for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }
done

values=(-f "$HERE/values-local.yaml")
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  cfg=$(mktemp)
  if [[ $MODE == multi ]]; then
    mkdir -p "$HERE/.amq-store"
    sed "s#__STORE__#$HERE/.amq-store#g" "$HERE/kind-multi.yaml" > "$cfg"
  else
    cp "$HERE/kind-single.yaml" "$cfg"
  fi
  kind create cluster --name "$CLUSTER" --config "$cfg"
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

if [[ $MODE == multi ]]; then
  values+=(-f "$HERE/values-local-multinode.yaml")
  zones=(a b c); i=0
  for n in $(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name); do
    kubectl label --overwrite "$n" "topology.kubernetes.io/zone=zone-${zones[$i]}" >/dev/null; i=$((i+1))
  done
  kubectl apply -f "$HERE/shared-pv.yaml"
fi

# Optional: pre-load the image to avoid Docker Hub rate limits (LOAD_IMAGE=1 ./up.sh)
if [[ ${LOAD_IMAGE:-0} == 1 ]]; then
  img=alfresco/alfresco-activemq:5.18-jre17-rockylinux8
  docker pull "$img" && kind load docker-image "$img" --name "$CLUSTER"
fi

helm upgrade --install "$REL" "$CHART" -n "$NS" --create-namespace "${values[@]}"

echo "waiting for a master..."
svc=$(kubectl -n "$NS" get svc -l "app.kubernetes.io/instance=$REL,amq.role=client" -o jsonpath='{.items[0].metadata.name}')
for _ in $(seq 1 120); do
  m=$(kubectl -n "$NS" get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].targetRef.name}' 2>/dev/null || true)
  [[ -n $m ]] && break; sleep 2
done
[[ -n ${m:-} ]] || { echo "no master after 4 min; check: kubectl -n $NS logs -l app.kubernetes.io/instance=$REL"; exit 1; }

kubectl -n "$NS" get pods -o wide
helm test "$REL" -n "$NS" --logs
cat <<INFO

Master: $m
  OpenWire  tcp://localhost:61616       (user alfresco / alfresco, admin / admin)
  STOMP     localhost:61613
  Console   http://localhost:8161
Next:  ./failover-smoke.sh      ../scripts/status.sh $REL $NS      ./down.sh
INFO
