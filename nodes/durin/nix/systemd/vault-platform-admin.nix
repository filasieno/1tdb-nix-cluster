{ lib, commands, ... }:
{
  # Flux creates the service account. This unit binds it to cluster-admin
  # and enables Vault kubernetes auth for that account. It retries until
  # both the API and the account exist.
  systemd.services.vault-platform-admin = {
    description = "Grant vault-platform-admin-sa cluster-admin and enable Vault kubernetes auth";
    wantedBy = [ "multi-user.target" ];
    after = [
      "vault-init.service"
      "kube-apiserver.service"
      "etcd.service"
    ];
    wants = [
      "vault-init.service"
      "kube-apiserver.service"
      "etcd.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "10s";
      TimeoutStartSec = "900s";
      ExecStart = lib.getExe commands.vaultPlatformAdmin;
    };
    unitConfig.StartLimitIntervalSec = 0;
  };
}
