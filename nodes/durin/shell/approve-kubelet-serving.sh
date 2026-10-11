#!/usr/bin/env bash
# shellcheck shell=bash
# approve-kubelet-serving.sh — approve kubelet serving CSRs on cluster.bootstrap.
#
# kubelet-serving-csr-approve.timer runs this only on the bootstrap control
# member. A CSR is approved only when all of these hold:
#   signerName is kubernetes.io/kubelet-serving
#   the CN is system:node:<name>
#   <name> is a worker in cluster.members
#   every IP SAN equals that member's address
# Any other CSR is left untouched.
#
# kubectl uses the cluster-admin kubeconfig and talks to the local API.
# etcdctl lock takes cluster/reconcile/kubelet-serving-csr, the same shape as
# the other one-step cluster jobs.
#
# Environment, set by the Nix wrapper:
#   KUBELET_SERVING_APPROVER    1 only on cluster.bootstrap
#   KUBELET_SERVING_WORKERS     JSON object of worker hostname to address
#   KUBECONFIG                  cluster-admin kubeconfig
#   ETCDCTL_ENDPOINTS, ETCDCTL_CACERT, ETCDCTL_CERT, ETCDCTL_KEY
#
# Wrapped by the command derivation (errexit, nounset, pipefail).

if [[ ${KUBELET_SERVING_APPROVER:-0} != 1 ]]; then
  echo "kubelet-serving-csr: only cluster.bootstrap approves serving CSRs" >&2
  exit 1
fi

if [[ ${KUBELET_SERVING_LOCK_HELD:-} != 1 ]]; then
  export KUBELET_SERVING_LOCK_HELD=1
  exec etcdctl lock cluster/reconcile/kubelet-serving-csr --ttl=60 -- "$0"
fi

kubeconfig=${KUBECONFIG:?}
if [[ ! -s $kubeconfig ]]; then
  echo "kubelet-serving-csr: cluster admin kubeconfig is missing" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl --kubeconfig="$kubeconfig" config view --raw >"$tmp/kubeconfig"
kubectl --kubeconfig="$tmp/kubeconfig" config set-cluster local --server=https://127.0.0.1:6443 >/dev/null
export KUBECONFIG=$tmp/kubeconfig

if ! list=$(kubectl get csr --output=json --request-timeout=15s); then
  echo "kubelet-serving-csr: cannot list CSRs" >&2
  exit 1
fi

while IFS= read -r item; do
  [[ -n $item ]] || continue
  signer=$(jq -r '.spec.signerName // ""' <<<"$item")
  if [[ $signer != "kubernetes.io/kubelet-serving" ]]; then
    continue
  fi

  csr_name=$(jq -r '.metadata.name' <<<"$item")
  if jq -e 'any(.status.conditions[]?; (.type == "Approved" or .type == "Denied") and .status == "True")' <<<"$item" >/dev/null; then
    continue
  fi

  request=$(jq -r '.spec.request // ""' <<<"$item")
  if [[ -z $request ]] || ! printf '%s' "$request" | base64 -d >"$tmp/req.csr" 2>/dev/null; then
    echo "kubelet-serving-csr: not approving ${csr_name}: request is not a certificate request" >&2
    continue
  fi

  if ! subject=$(openssl req -in "$tmp/req.csr" -noout -subject -nameopt RFC2253); then
    echo "kubelet-serving-csr: not approving ${csr_name}: request is not a certificate request" >&2
    continue
  fi
  if [[ $subject =~ CN=([^,+]+) ]]; then
    cn=${BASH_REMATCH[1]}
  else
    echo "kubelet-serving-csr: not approving ${csr_name}: no common name" >&2
    continue
  fi
  prefix="system:node:"
  if [[ $cn != "$prefix"* || $cn == "$prefix" ]]; then
    echo "kubelet-serving-csr: not approving ${csr_name}: common name is not system:node:<name>" >&2
    continue
  fi
  node=${cn#"$prefix"}

  if ! addr=$(jq -er --arg n "$node" '.[$n] // empty' <<<"$KUBELET_SERVING_WORKERS"); then
    echo "kubelet-serving-csr: not approving ${csr_name}: ${node} is not a worker in cluster.members" >&2
    continue
  fi

  text=$(openssl req -in "$tmp/req.csr" -noout -text)
  ips=()
  rest=$text
  while [[ $rest =~ IP\ Address:([0-9.]+) ]]; do
    ips+=("${BASH_REMATCH[1]}")
    rest=${rest#*"IP Address:${BASH_REMATCH[1]}"}
  done
  if ((${#ips[@]} == 0)); then
    echo "kubelet-serving-csr: not approving ${csr_name}: ${node} has no IP SAN" >&2
    continue
  fi
  match=1
  for ip in "${ips[@]}"; do
    if [[ $ip != "$addr" ]]; then
      match=0
    fi
  done
  if [[ $match != 1 ]]; then
    echo "kubelet-serving-csr: not approving ${csr_name}: IP SANs for ${node} are not that member's address" >&2
    continue
  fi

  kubectl certificate approve "$csr_name" --request-timeout=15s >/dev/null
done < <(jq -c '.items[]?' <<<"$list")
