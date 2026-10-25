#!/usr/bin/env bash
# Show master/standby and where the client Service routes.
# Usage: scripts/status.sh <release> [namespace]
set -euo pipefail
REL=${1:?usage: $0 <release> [namespace]}
NS=${2:-default}
kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=$REL,app.kubernetes.io/name=alfresco-activemq-ha" -o wide
svc=$(kubectl -n "$NS" get svc -l "app.kubernetes.io/instance=$REL,amq.role=client" -o jsonpath='{.items[0].metadata.name}')
echo
echo "service $svc -> master: $(kubectl -n "$NS" get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].targetRef.name}')"
