#!/usr/bin/env bash
set -Eeuo pipefail
children=()
cleanup() { for child in "${children[@]}"; do kill "$child" 2>/dev/null || true; done; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
kubectl -n monitoring port-forward --address=127.0.0.1 service/grafana 3000:80 &
children+=("$!")
kubectl -n chaos-mesh port-forward --address=127.0.0.1 service/chaos-dashboard 2333:2333 &
children+=("$!")
kubectl -n monitoring port-forward --address=127.0.0.1 service/monitoring-prometheus 9090:9090 &
children+=("$!")
printf '\nKeep this terminal open. Grafana :3000; Chaos Dashboard :2333; Prometheus :9090.\n'
wait -n "${children[@]}"
