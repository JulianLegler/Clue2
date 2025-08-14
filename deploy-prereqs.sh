#!/usr/bin/env bash
set -euo pipefail

# Installs CLUE2 prerequisites into a dedicated namespace:
# - kube-prometheus-stack (Prometheus, Node Exporter, Grafana)
# - Kepler (energy monitoring)
# Optionally labels worker nodes with scaphandre=true for scheduling.
#
# Configurable via env vars:
#   NAMESPACE                Namespace for all prereqs (default: clue-prereqs)
#   PROM_RELEASE             Helm release name for kube-prometheus-stack (default: clue-kps)
#   KEPLER_RELEASE           Helm release name for Kepler (default: clue-kepler)
#   LABEL_WORKERS            Whether to label worker nodes with scaphandre=true (default: true)
#   K8S_CONTEXT              Optional kubectl context to target (default: current context)
#   CLEANUP_EXISTING         Whether to clean up existing CLUE2 resources before installing (default: false)
#
# Example:
#   NAMESPACE=clue-prereqs ./deploy-prereqs.sh
#   CLEANUP_EXISTING=true ./deploy-prereqs.sh

NAMESPACE=${NAMESPACE:-clue-prereqs}
PROM_RELEASE=${PROM_RELEASE:-clue-kps}
KEPLER_RELEASE=${KEPLER_RELEASE:-clue-kepler}
LABEL_WORKERS=${LABEL_WORKERS:-true}
K8S_CONTEXT=${K8S_CONTEXT:-}
CLEANUP_EXISTING=${CLEANUP_EXISTING:-false}

kubectl_cmd=(kubectl)
helm_cmd=(helm)

if [[ -n "${K8S_CONTEXT}" ]]; then
  kubectl_cmd+=(--context "${K8S_CONTEXT}")
  helm_cmd+=(--kube-context "${K8S_CONTEXT}")
fi

echo "[INFO] Using namespace: ${NAMESPACE}"
echo "[INFO] Helm releases: ${PROM_RELEASE} (kube-prometheus-stack), ${KEPLER_RELEASE} (kepler)"
echo "[INFO] Cleanup existing: ${CLEANUP_EXISTING}"

if [[ "${CLEANUP_EXISTING}" == "true" ]]; then
  echo "[STEP] Cleaning up existing CLUE2 resources"
  # Uninstall CLUE2 Helm release first (this will clean up resources in the namespace)
  "${helm_cmd[@]}" --namespace clue uninstall clue  || true
  # Clean up cluster-wide resources that might not be managed by Helm
  "${kubectl_cmd[@]}" delete clusterrole clue-deployer-cluster-role --ignore-not-found  || true
  "${kubectl_cmd[@]}" delete clusterrolebinding clue-deployer-cluster-binding --ignore-not-found  || true
  # Then delete the namespaces (Helm will handle this properly)
  "${kubectl_cmd[@]}" delete namespace clue --ignore-not-found  || true
  "${kubectl_cmd[@]}" delete namespace toystore --ignore-not-found  || true
  echo "[OK] Cleanup completed"
fi

echo "[STEP] Adding/Updating Helm repos"
"${helm_cmd[@]}" repo add prometheus-community https://prometheus-community.github.io/helm-charts  || true
"${helm_cmd[@]}" repo add kepler https://sustainable-computing-io.github.io/kepler-helm-chart/  || true
"${helm_cmd[@]}" repo update >/dev/null

echo "[STEP] Checking namespace: ${NAMESPACE}"
# Let Helm create the namespace with proper annotations during installation
# Only create manually if it doesn't exist and we're not using --create-namespace
"${kubectl_cmd[@]}" create namespace toystore || true

echo "[STEP] Installing/Upgrading kube-prometheus-stack"
# We keep default service types (ClusterIP) for Prometheus/Grafana to be cluster-internal.
# Expose externally via your own Ingress/Port-forwarding if needed.
"${helm_cmd[@]}" upgrade --install "${PROM_RELEASE}" prometheus-community/kube-prometheus-stack \
  --namespace "${NAMESPACE}" --create-namespace \
  --set grafana.enabled=true \
  --wait --timeout 15m

echo "[STEP] Installing/Upgrading Kepler"
"${helm_cmd[@]}" upgrade --install "${KEPLER_RELEASE}" kepler/kepler \
  --namespace "${NAMESPACE}" \
  --wait --timeout 10m

if [[ "${LABEL_WORKERS}" == "true" ]]; then
  echo "[STEP] Labeling worker nodes with scaphandre=true (idempotent)"
  # Try to find non-control-plane nodes by common labels; fallback to all nodes if none matched
  mapfile -t worker_nodes < <( "${kubectl_cmd[@]}" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels}{"\n"}{end}' \
    | awk 'BEGIN{FS="\t"} {print $1"\t"$2}' \
    | grep -v 'node-role.kubernetes.io/control-plane\|node-role.kubernetes.io/master' \
    | awk '{print $1}' ) || true

  if [[ ${#worker_nodes[@]} -eq 0 ]]; then
    echo "[WARN] No worker nodes detected by control-plane label filter; labeling all nodes instead"
    mapfile -t worker_nodes < <( "${kubectl_cmd[@]}" get nodes -o name | awk -F/ '{print $2}' ) || true
  fi

  for node in "${worker_nodes[@]:-}"; do
    [[ -z "$node" ]] && continue
    echo "  - labeling node: $node"
    "${kubectl_cmd[@]}" label node "$node" scaphandre=true --overwrite >/dev/null
  done
fi

echo "[OK] Prerequisites installed in namespace '${NAMESPACE}'."
echo "[HINT] Set your CLUE values to use the in-cluster Prometheus service (ClusterIP)."
echo "       List services to identify Prometheus and Grafana endpoints: kubectl -n ${NAMESPACE} get svc"
echo "       Example port-forwards:"
echo "         Prometheus: kubectl -n ${NAMESPACE} port-forward svc/<prometheus-svc-name> 9090:9090"
echo "         Grafana:    kubectl -n ${NAMESPACE} port-forward svc/<grafana-svc-name> 3000:80"


