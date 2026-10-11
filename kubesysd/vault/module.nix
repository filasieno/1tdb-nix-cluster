# Wrapper. Installs no binary. Imports OpenBao and Vault Community, and fails
# closed when the cluster module does not define cluster.vault or cluster.vaultNodes.
{ check }:
{
  config,
  options,
  lib,
  ...
}:
let
  openbao = import ../openbao/module.nix;
  vaultCommunity = import ../vault-community/module.nix;
  hasVault = options.cluster ? vault;
  hasNodes = options.cluster ? vaultNodes;
  # Nix if is lazy. config.cluster.vault and config.cluster.vaultNodes are
  # not evaluated unless both options exist.
  lengthAssertions =
    if hasVault && hasNodes then
      let
        selected = config.cluster.vault;
        nodes = config.cluster.vaultNodes;
      in
      [
        {
          assertion = selected != "vault-community" || (builtins.isList nodes && lib.length nodes == 1);
          message = "cluster.vault is \"vault-community\". cluster.vaultNodes must list exactly one member.";
        }
      ]
    else
      [ ];
in
{
  imports = [
    (openbao { inherit check; })
    (vaultCommunity { inherit check; })
  ];

  config.assertions = [
    {
      assertion = hasNodes;
      message = "The cluster module must define the option cluster.vaultNodes.";
    }
    {
      assertion = hasVault;
      message = "The cluster module must define the option cluster.vault.";
    }
  ]
  ++ lengthAssertions;
}
