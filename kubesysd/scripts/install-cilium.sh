# install-cilium.sh — install or upgrade the pinned Cilium chart.
#
# cilium-install.service runs this after kube-apiserver and kubelet are up,
# on the bootstrap control plane only. helm upgrade --install is idempotent.
# The command retries while the API is still settling, then exits 0 on the
# first successful upgrade.
#
# Environment, set by the Nix wrapper:
#   CILIUM_CHART   path of the Cilium chart tarball
#   CILIUM_VALUES  path of the values file
# Extra arguments are forwarded to helm.
#
# KUBECONFIG defaults to /etc/kubernetes/cluster-admin.kubeconfig.
# nss-myhostname answers the machine name with 127.0.0.2, which is not on
# the apiserver certificate, so the client talks to 127.0.0.1:6443.
#
# Wrapped by pkgs.writeShellApplication (errexit, nounset, pipefail; PATH
# includes helm and kubectl).

if [[ "${CILIUM_LOCK_HELD:-}" != 1 && -n "${ETCDCTL_CACERT:-}" && -s "$ETCDCTL_CACERT" ]]; then
  export CILIUM_LOCK_HELD=1
  exec etcdctl lock cluster/reconcile/cilium --ttl=180 -- "$0"
fi

kubeconfig="${KUBECONFIG:-/etc/kubernetes/cluster-admin.kubeconfig}"

if [[ ! -s "$kubeconfig" ]]; then
  echo "cluster admin kubeconfig is missing: $kubeconfig" >&2
  exit 1
fi

tmp="$(mktemp)"
kubectl --kubeconfig="$kubeconfig" config view --raw >"$tmp"
kubectl --kubeconfig="$tmp" config set-cluster local --server=https://127.0.0.1:6443 >/dev/null
export KUBECONFIG="$tmp"

ready=0
for ((i = 0; i < 90; i++)); do
  if kubectl get --raw=/readyz >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "$ready" -ne 1 ]]; then
  echo "kube-apiserver did not become ready" >&2
  exit 1
fi

for ((i = 0; i < 30; i++)); do
  if helm upgrade --install cilium "$CILIUM_CHART" \
    --namespace kube-system \
    --create-namespace \
    --values "$CILIUM_VALUES" \
    "$@"; then
    exit 0
  fi
  sleep 2
done
exit 1
