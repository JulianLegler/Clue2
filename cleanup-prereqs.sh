#!/usr/bin/env bash
set -euo pipefail

# Removes CLUE2 prerequisite deployments from a dedicated namespace and reverts optional labels.
#
# Configurable via env vars:
#   NAMESPACE       Namespace used for prereqs (default: clue-prereqs)
#   PROM_RELEASE    Helm release name for kube-prometheus-stack (default: clue-kps)
#   KEPLER_RELEASE  Helm release name for Kepler (default: clue-kepler)
#   UNLABEL_WORKERS Whether to remove scaphandre=true label from nodes (default: false)
#   K8S_CONTEXT     Optional kubectl context to target (default: current context)

NAMESPACE=${NAMESPACE:-clue-prereqs}
PROM_RELEASE=${PROM_RELEASE:-clue-kps}
KEPLER_RELEASE=${KEPLER_RELEASE:-clue-kepler}
UNLABEL_WORKERS=${UNLABEL_WORKERS:-false}
K8S_CONTEXT=${K8S_CONTEXT:-}

kubectl_cmd=(kubectl)
helm_cmd=(helm)

if [[ -n "${K8S_CONTEXT}" ]]; then
  kubectl_cmd+=(--context "${K8S_CONTEXT}")
  helm_cmd+=(--kube-context "${K8S_CONTEXT}")
fi

echo "[STEP] Uninstalling Helm releases (if present)"
"${helm_cmd[@]}" --namespace "${NAMESPACE}" uninstall "${KEPLER_RELEASE}" >/dev/null 2>&1 || true
"${helm_cmd[@]}" --namespace "${NAMESPACE}" uninstall "${PROM_RELEASE}" >/dev/null 2>&1 || true

if [[ "${UNLABEL_WORKERS}" == "true" ]]; then
  echo "[STEP] Removing scaphandre label from nodes (idempotent)"
  mapfile -t labeled_nodes < <( "${kubectl_cmd[@]}" get nodes -l scaphandre=true -o name | awk -F/ '{print $2}' ) || true
  for node in "${labeled_nodes[@]:-}"; do
    [[ -z "$node" ]] && continue
    echo "  - unlabeling node: $node"
    "${kubectl_cmd[@]}" label node "$node" scaphandre- >/dev/null || true
  done
fi

echo "[STEP] Deleting namespace if empty or if you want to force it"
"${kubectl_cmd[@]}" delete ns "${NAMESPACE}" --ignore-not-found

echo "[OK] Cleanup completed."


