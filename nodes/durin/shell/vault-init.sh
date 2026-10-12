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
#   VAULT_ROOT_TOKEN_FILE       root-only handoff for vault-platform-admin.
#                               Written only while the init JSON is still in
#                               hand, and removed once kubernetes login works.
#
# Wrapped by the command derivation (errexit, nounset, pipefail).

sealed=/var/lib/vault/recovery.age
pending=/dev/shm/vault-init/recovery.json
root_token=${VAULT_ROOT_TOKEN_FILE:?}

install -d -m 0700 -o root -g root /dev/shm/vault-init

scrub() {
  local src=$1
  if [[ -e $src ]]; then
    shred --remove "$src" || rm -f "$src"
  fi
}

# The age bundle is the copy the admins can read. The root token file is
# the copy this host needs once, so vault-platform-admin can turn on
# kubernetes auth before that token is discarded. An existing file is left
# alone: it may be the only remaining admin credential.
capture_root_token() {
  local src=$1
  local token tmp
  if [[ ! -s $src || -s $root_token ]]; then
    return 0
  fi
  token=$(jq -r .root_token "$src")
  if [[ -z $token || $token == "null" ]]; then
    echo "init response has no root token" >&2
    return 1
  fi
  tmp=$(mktemp /dev/shm/vault-init/root.token.XXXXXX)
  printf '%s\n' "$token" >"$tmp"
  install -d -m 0700 -o root -g root "$(dirname "$root_token")"
  install -m 0400 -o root -g root "$tmp" "$root_token"
  shred --remove "$tmp" || rm -f "$tmp"
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
  capture_root_token "$pending"
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
    capture_root_token "$pending"
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
