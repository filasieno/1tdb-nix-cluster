# openbao-init.sh — initialize OpenBao once, on cluster.bootstrap only.
#
# OPENBAO_BOOTSTRAP is set by the module. It is 1 only when
# networking.hostName is cluster.bootstrap. Only that member initializes
# OpenBao, under the etcd lock cluster/reconcile/openbao-init.
#
# Every other control member leaves before that call. It polls bao status
# until initialized=true. Raft retry_join attaches it to the cluster the
# bootstrap member formed. If OpenBao is not initialized yet, the script
# exits non-zero and systemd retries. It does not create a second Raft cluster.
#
# Auto-unseal is the azurekeyvault seal inside openbao.service.
#
# On the bootstrap member, the recovery JSON is encrypted with age to
# OPENBAO_RECOVERY_RECIPIENT and stored at /var/lib/openbao/recovery.age.
# The private key is not on this host.
#
# Environment, set by the Nix wrapper:
#   OPENBAO_BOOTSTRAP
#   BAO_ADDR
#   OPENBAO_RECOVERY_RECIPIENT
#   ETCDCTL_ENDPOINTS, ETCDCTL_CACERT, ETCDCTL_CERT, ETCDCTL_KEY
#
# Wrapped by pkgs.writeShellApplication (errexit, nounset, pipefail).

bootstrap=${OPENBAO_BOOTSTRAP:-0}

poll_status() {
  status=""
  local code=1
  local _
  for _ in $(seq 1 90); do
    set +e
    status=$(bao status -format=json)
    code=$?
    set -e
    if [[ $code -eq 0 || ($code -eq 2 && -n $status) ]]; then
      return 0
    fi
    sleep 1
    status=""
  done
  return 1
}

initialized() {
  [[ $(jq -r .initialized <<<"$status") == "true" ]]
}

if [[ $bootstrap != 1 ]]; then
  if ! poll_status; then
    echo "openbao-init: bao status did not answer" >&2
    exit 1
  fi
  if initialized; then
    exit 0
  fi
  echo "openbao-init: this member is not cluster.bootstrap. Refusing to initialize. OpenBao is not initialized yet; retry_join attaches this node once the bootstrap member has initialized." >&2
  exit 1
fi

if [[ ${OPENBAO_LOCK_HELD:-} != 1 ]]; then
  export OPENBAO_LOCK_HELD=1
  exec etcdctl lock cluster/reconcile/openbao-init --ttl=60 -- "$0"
fi

sealed=/var/lib/openbao/recovery.age
pending=/dev/shm/openbao-init/recovery.json

install -d -m 0750 -o root -g openbao /var/lib/openbao
install -d -m 0700 -o root -g root /dev/shm/openbao-init

scrub() {
  local src=$1
  if [[ -e $src ]]; then
    shred --remove "$src" || rm -f "$src"
  fi
}

encrypt_file() {
  local src=$1
  local tmp
  if [[ ! -s $src ]]; then
    return 0
  fi
  tmp=$(mktemp /dev/shm/openbao-init/recovery.age.XXXXXX)
  age --recipient "$OPENBAO_RECOVERY_RECIPIENT" --armor --output "$tmp" "$src"
  install -m 0400 -o root -g root "$tmp" "$sealed"
  rm -f "$tmp"
  scrub "$src"
}

if [[ -s $sealed ]]; then
  scrub "$pending"
  exit 0
fi

encrypt_file "$pending"
if [[ -s $sealed ]]; then
  exit 0
fi

if ! poll_status; then
  echo "bao status did not answer" >&2
  exit 1
fi

if initialized; then
  exit 0
fi

umask 077
# BOOTSTRAP_OPERATOR_INIT
bao operator init \
  -recovery-shares=1 \
  -recovery-threshold=1 \
  -format=json >"$pending"
encrypt_file "$pending"

if [[ ! -s $sealed ]]; then
  echo "recovery bundle was not encrypted" >&2
  exit 1
fi
