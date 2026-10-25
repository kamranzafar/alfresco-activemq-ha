#!/usr/bin/env bash
# Delete the local cluster and the shared store directory.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
kind delete cluster --name "${CLUSTER:-amq-local}"
rm -rf "$HERE/.amq-store"
