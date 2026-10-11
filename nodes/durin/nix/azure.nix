# Azure Key Vault values for Vault Community auto-unseal.
#
# Tenant, client, vault, and key names identify things and are not secret.
# The one secret is the client secret. It lives in secrets/azure-client-secret.cred,
# a systemd credential sealed to durin's TPM 2.0 by `vault-seal-credential`.
# Only that chip can open it, so the file is safe in this public repo.
# systemd unseals it when vault.service starts; nothing is copied onto the
# host outside the flake. The clear text is kept for re-sealing in
# secrets/secrets.yaml, sops-encrypted to the admin age keys.
{
  tenantId = "50958d1d-f8c3-4774-8581-759ee70c1d32";
  clientId = "f4619c34-21da-4a3a-b667-524e6ded923a";
  vaultName = "BootstrapKeys";
  keyName = "vault-unseal";
  credentialName = "azure-client-secret";
  credentialFile = ../secrets/azure-client-secret.cred;
}
