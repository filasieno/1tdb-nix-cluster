# vault-init.sh — initialize HashiCorp Vault Community once on its single node.
#
# There is no etcd lock. cluster.vaultNodes has exactly one entry when this
# unit is installed, so no second node can initialize. The recovery file is
# the once-only guard.
#
# Auto-unseal is the azurekeyvault seal inside vault.service.
#
# The recovery JSON is encrypted with age to VAULT_RECOVERY_RECIPIENT and
# stored at /var/lib/vault/recovery.age. The private key is not on this host.
#
# Environment, set by the Nix wrapper:
#   VAULT_ADDR
#   VAULT_RECOVERY_RECIPIENT
#
# Wrapped by pkgs.writeShellApplication (errexit, nounset, pipefail).

sealed=/var/lib/vault/recovery.age
pending=/dev/shm/vault-init/recovery.json

install -d -m 0700 -o root -g root /dev/shm/vault-init

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
  tmp=$(mktemp /dev/shm/vault-init/recovery.age.XXXXXX)
  age --recipient "$VAULT_RECOVERY_RECIPIENT" --armor --output "$tmp" "$src"
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

status=""
code=1
for _ in $(seq 1 90); do
  set +e
  status=$(vault status -format=json)
  code=$?
  set -e
  if [[ $code -eq 0 || ($code -eq 2 && -n $status) ]]; then
    break
  fi
  status=""
  sleep 1
done

if [[ -z $status ]]; then
  echo "vault status did not answer" >&2
  exit 1
fi

if [[ $(jq -r .initialized <<<"$status") == "true" ]]; then
  exit 0
fi

umask 077
vault operator init \
  -recovery-shares=1 \
  -recovery-threshold=1 \
  -format=json >"$pending"
encrypt_file "$pending"

if [[ ! -s $sealed ]]; then
  echo "recovery bundle was not encrypted" >&2
  exit 1
fi
