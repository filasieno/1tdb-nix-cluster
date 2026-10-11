#!/usr/bin/env bash
# shellcheck shell=bash
# vault-init.sh — initialize HashiCorp Vault Community once on this node.
#
# Durin is the only Vault node, so nothing else can initialize it. The
# recovery file is the once-only guard.
#
# Auto-unseal is the azurekeyvault seal. This unit returns only when
# vault status reports sealed=false. A recovery file alone is not success.
#
# The recovery JSON is encrypted with age to every recipient in
# VAULT_RECOVERY_RECIPIENTS and stored at /var/lib/vault/recovery.age.
# The private keys are not on this host.
#
# Environment, set by the Nix wrapper:
#   VAULT_ADDR
#   VAULT_RECOVERY_RECIPIENTS   newline-separated age recipients
#
# Wrapped by the command derivation (errexit, nounset, pipefail).

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
  recipients=()
  while IFS= read -r recipient; do
    [[ -n $recipient ]] || continue
    recipients+=(--recipient "$recipient")
  done <<<"$VAULT_RECOVERY_RECIPIENTS"
  age "${recipients[@]}" --armor --output "$tmp" "$src"
  install -m 0400 -o root -g root "$tmp" "$sealed"
  rm -f "$tmp"
  scrub "$src"
}

status=""
code=1

read_status() {
  local _
  for _ in $(seq 1 90); do
    if poll; then
      return 0
    fi
    status=""
    sleep 1
  done
  echo "vault status did not answer" >&2
  return 1
}

poll() {
  set +e
  status=$(vault status -format=json)
  code=$?
  set -e
  [[ $code -eq 0 || ($code -eq 2 && -n $status) ]]
}

wait_unsealed() {
  local _
  for _ in $(seq 1 180); do
    if poll && [[ $code -eq 0 && $(jq -r .sealed <<<"$status") == "false" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "vault stayed sealed; Azure Key Vault auto-unseal did not complete" >&2
  return 1
}

if [[ -s $sealed ]]; then
  scrub "$pending"
else
  encrypt_file "$pending"
fi

if [[ ! -s $sealed ]]; then
  read_status
  if [[ $(jq -r .initialized <<<"$status") != "true" ]]; then
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
  else
    echo "vault is already initialized and recovery.age is absent" >&2
  fi
fi

read_status
if [[ $(jq -r .initialized <<<"$status") != "true" ]]; then
  echo "recovery bundle exists but vault is not initialized" >&2
  exit 1
fi

if ! wait_unsealed; then
  echo "vault stayed sealed; restarting vault.service once so Azure unseal runs again" >&2
  systemctl restart vault.service
  wait_unsealed
fi
