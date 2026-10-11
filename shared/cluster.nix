# Shared cluster values. A node build fails unless networking.hostName is
# a key in members. Balin is intentionally absent until it joins.
let
  recipients = import ./recipients.nix;
in
{
  cluster.enable = true;
  cluster.name = "1tdb";
  cluster.etcd.initialClusterToken = "1tdb-1";
  cluster.kubernetes = {
    serviceCidr = "10.0.0.0/24";
    serviceIp = "10.0.0.1";
    podCidr = "10.1.0.0/16";
  };
  cluster.vault = "openbao";
  # Durin is the only OpenBao process. Control membership does not add another.
  cluster.vaultNodes = [ "durin" ];
  cluster.openbao = {
    azureVaultName = "BootstrapKeys";
    azureKeyName = "vault-unseal";
    recoveryRecipient = recipients.fabio;
  };
  # Durin is still DHCP. 127.0.0.1 is the only known address.
  # It must become a reachable address before a second member joins.
  cluster.members.durin = {
    control = true;
    worker = true;
    address = "127.0.0.1";
  };
}
