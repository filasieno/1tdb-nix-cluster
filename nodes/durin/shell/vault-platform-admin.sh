#!/usr/bin/env bash
# shellcheck shell=bash
# vault-platform-admin.sh — bootstrap declarative Vault administration.
#
# Flux creates the service account vault-platform-admin-sa and its token
# Secret. This unit then:
#   binds that account to cluster-admin
#   enables Vault's kubernetes auth method
#   writes an admin policy and a role for the account
#
# The first run authenticates to Vault with the root token vault-init left
# at VAULT_ROOT_TOKEN_FILE. That file is removed once a kubernetes login for
# this account succeeds. Later runs log in with the account and re-apply the
# same config. The unit retries until Flux has created the account.
#
# Environment, set by the Nix wrapper:
#   VAULT_ADDR
#   KUBECONFIG
#   VAULT_KUBERNETES_HOST
#   VAULT_KUBERNETES_CA
#   VAULT_KUBERNETES_ISSUER
#   VAULT_PLATFORM_NAMESPACE
#   VAULT_PLATFORM_SERVICE_ACCOUNT
#   VAULT_PLATFORM_TOKEN_SECRET
#   VAULT_PLATFORM_ROLE
#   VAULT_PLATFORM_POLICY
#   VAULT_ROOT_TOKEN_FILE
#   ETCDCTL_ENDPOINTS, ETCDCTL_CACERT, ETCDCTL_CERT, ETCDCTL_KEY
#
# Wrapped by the command derivation (errexit, nounset, pipefail).

if [[ ${VAULT_PLATFORM_ADMIN_LOCK_HELD:-} != 1 ]]; then
  export VAULT_PLATFORM_ADMIN_LOCK_HELD=1
  exec etcdctl lock cluster/reconcile/vault-platform-admin --ttl=600 -- "$0"
fi

: "${VAULT_ADDR:?}"
: "${KUBECONFIG:?}"
: "${VAULT_KUBERNETES_HOST:?}"
: "${VAULT_KUBERNETES_CA:?}"
: "${VAULT_KUBERNETES_ISSUER:?}"
: "${VAULT_PLATFORM_NAMESPACE:?}"
: "${VAULT_PLATFORM_SERVICE_ACCOUNT:?}"
: "${VAULT_PLATFORM_TOKEN_SECRET:?}"
: "${VAULT_PLATFORM_ROLE:?}"
: "${VAULT_PLATFORM_POLICY:?}"
: "${VAULT_ROOT_TOKEN_FILE:?}"

secrets=()
scrub() {
  local src
  for src in "$@"; do
    if [[ -e $src ]]; then
      shred --remove "$src" || rm -f "$src"
    fi
  done
}
cleanup() {
  if ((${#secrets[@]} > 0)); then
    scrub "${secrets[@]}"
  fi
}
trap cleanup EXIT

wait_unsealed() {
  local _
  local status=""
  local code=1
  for _ in $(seq 1 30); do
    set +e
    status=$(vault status -format=json)
    code=$?
    set -e
    if [[ $code -eq 0 && $(jq -r .sealed <<<"$status") == "false" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "vault is not unsealed" >&2
  return 1
}

wait_account() {
  local _
  for _ in $(seq 1 30); do
    if kubectl get serviceaccount "$VAULT_PLATFORM_SERVICE_ACCOUNT" \
      --namespace "$VAULT_PLATFORM_NAMESPACE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "service account ${VAULT_PLATFORM_NAMESPACE}/${VAULT_PLATFORM_SERVICE_ACCOUNT} is not in the API yet" >&2
  return 1
}

wait_reviewer() {
  local _
  local token
  for _ in $(seq 1 30); do
    token=$(kubectl get secret "$VAULT_PLATFORM_TOKEN_SECRET" \
      --namespace "$VAULT_PLATFORM_NAMESPACE" \
      -o go-template='{{index .data "token"}}' 2>/dev/null || true)
    if [[ -n $token ]]; then
      return 0
    fi
    sleep 2
  done
  echo "token secret ${VAULT_PLATFORM_NAMESPACE}/${VAULT_PLATFORM_TOKEN_SECRET} has no token yet" >&2
  return 1
}

kubernetes_login() {
  local jwt login code
  jwt=$(kubectl create token "$VAULT_PLATFORM_SERVICE_ACCOUNT" \
    --namespace "$VAULT_PLATFORM_NAMESPACE" \
    --duration 10m)
  login=$(mktemp /dev/shm/vault-platform-admin.XXXXXX)
  secrets+=("$login")
  chmod 0600 "$login"
  printf '%s' "$jwt" | tr -d '\r\n' >"$login"
  set +e
  VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login \
    role="$VAULT_PLATFORM_ROLE" \
    jwt="@${login}")
  code=$?
  set -e
  scrub "$login"
  if [[ $code -ne 0 || -z ${VAULT_TOKEN:-} ]]; then
    return 1
  fi
  export VAULT_TOKEN
}

acquire_admin() {
  if [[ -s $VAULT_ROOT_TOKEN_FILE ]]; then
    VAULT_TOKEN=$(tr -d '\r\n' <"$VAULT_ROOT_TOKEN_FILE")
    export VAULT_TOKEN
    if [[ -z $VAULT_TOKEN ]]; then
      echo "root token file is empty" >&2
      return 1
    fi
    return 0
  fi
  if kubernetes_login; then
    return 0
  fi
  echo "no root token and kubernetes auth login failed" >&2
  return 1
}

wait_unsealed
wait_account

kubectl apply --filename - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-platform-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: ${VAULT_PLATFORM_SERVICE_ACCOUNT}
    namespace: ${VAULT_PLATFORM_NAMESPACE}
EOF

if [[ $(kubectl auth can-i '*' '*' \
  --as="system:serviceaccount:${VAULT_PLATFORM_NAMESPACE}:${VAULT_PLATFORM_SERVICE_ACCOUNT}") != yes ]]; then
  echo "service account is not cluster-admin" >&2
  exit 1
fi

wait_reviewer

if ! acquire_admin; then
  exit 1
fi

if ! vault auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null; then
  vault auth enable kubernetes
fi

reviewer=$(kubectl get secret "$VAULT_PLATFORM_TOKEN_SECRET" \
  --namespace "$VAULT_PLATFORM_NAMESPACE" \
  -o go-template='{{.data.token | base64decode}}')
reviewer_file=$(mktemp /dev/shm/vault-platform-admin.XXXXXX)
secrets+=("$reviewer_file")
chmod 0600 "$reviewer_file"
printf '%s' "$reviewer" | tr -d '\r\n' >"$reviewer_file"
unset reviewer

vault write auth/kubernetes/config \
  kubernetes_host="$VAULT_KUBERNETES_HOST" \
  kubernetes_ca_cert="@${VAULT_KUBERNETES_CA}" \
  token_reviewer_jwt="@${reviewer_file}" \
  issuer="$VAULT_KUBERNETES_ISSUER" \
  disable_local_ca_jwt=true

vault policy write "$VAULT_PLATFORM_POLICY" - <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

vault write "auth/kubernetes/role/${VAULT_PLATFORM_ROLE}" \
  bound_service_account_names="$VAULT_PLATFORM_SERVICE_ACCOUNT" \
  bound_service_account_namespaces="$VAULT_PLATFORM_NAMESPACE" \
  policies="$VAULT_PLATFORM_POLICY" \
  ttl=1h

if ! kubernetes_login; then
  echo "vault kubernetes auth rejected ${VAULT_PLATFORM_NAMESPACE}/${VAULT_PLATFORM_SERVICE_ACCOUNT}" >&2
  exit 1
fi

if [[ -e $VAULT_ROOT_TOKEN_FILE ]]; then
  scrub "$VAULT_ROOT_TOKEN_FILE"
fi

echo "vault kubernetes auth role ${VAULT_PLATFORM_ROLE} accepts ${VAULT_PLATFORM_NAMESPACE}/${VAULT_PLATFORM_SERVICE_ACCOUNT}"
