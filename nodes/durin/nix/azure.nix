# Azure Key Vault values for Vault Community auto-unseal.
# vaultName and keyName are not secret. The three credentials are the
# keys in secrets/secrets.yaml. Their values stay in that file.
{
  vaultName = "BootstrapKeys";
  keyName = "vault-unseal";
  tenantIdKey = "azure_tenant_id";
  clientIdKey = "azure_client_id";
  clientSecretKey = "azure_client_secret";
}
