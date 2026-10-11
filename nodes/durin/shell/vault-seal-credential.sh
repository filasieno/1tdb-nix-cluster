#!/usr/bin/env bash
# shellcheck shell=bash
# vault-seal-credential.sh — seal the Azure client secret to this host's TPM.
#
# Reads the clear-text secret on stdin and writes a systemd encrypted
# credential on stdout, Base64 text, suitable for LoadCredentialEncrypted=.
# The key never leaves the TPM: --with-key=tpm2 avoids the per-install host
# key in /var/lib/systemd/credential.secret, and an empty PCR list means
# firmware or kernel updates cannot lock Vault out. Only this chip can open
# the result, so the file is committed to the repo.
#
# Run as root on durin:
#   sops -d --extract '["azure_client_secret"]' nodes/durin/secrets/secrets.yaml \
#     | ssh durin sudo vault-seal-credential > nodes/durin/secrets/azure-client-secret.cred
#
# Environment, set by the Nix wrapper:
#   VAULT_CREDENTIAL_NAME   credential id, must match LoadCredentialEncrypted=

if [[ $(id -u) -ne 0 ]]; then
  echo "vault-seal-credential: run as root, the TPM device is root-only" >&2
  exit 1
fi
if ! systemd-creds has-tpm2 >/dev/null 2>&1; then
  echo "vault-seal-credential: no usable TPM 2.0 (systemd-creds has-tpm2 failed); enable fTPM in the BIOS" >&2
  exit 1
fi

umask 077
work=$(mktemp -d /dev/shm/vault-seal.XXXXXX)
trap 'rm -rf "$work"' EXIT

tr -d '\r\n' >"$work/secret"
if [[ ! -s $work/secret ]]; then
  echo "vault-seal-credential: empty secret on stdin" >&2
  exit 1
fi

systemd-creds encrypt \
  --with-key=tpm2 \
  --tpm2-device=auto \
  --tpm2-pcrs= \
  --name="$VAULT_CREDENTIAL_NAME" \
  "$work/secret" - >"$work/cred"

# Prove the chip gives it back before anyone commits the file.
if ! cmp -s "$work/secret" <(systemd-creds decrypt --name="$VAULT_CREDENTIAL_NAME" "$work/cred" -); then
  echo "vault-seal-credential: round trip through the TPM failed" >&2
  exit 1
fi

cat "$work/cred"
