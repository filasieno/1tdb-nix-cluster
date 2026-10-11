{ config, lib }:
let
  host = config.networking.hostName;
  members = config.cluster.members;
  known = builtins.hasAttr host members;
  me = if known then members.${host} else null;
  secrets = config.cluster.kubernetes.secretsDir;
in
rec {
  inherit
    host
    known
    me
    secrets
    ;
  cert = name: "${secrets}/${name}.pem";
  key = name: "${secrets}/${name}-key.pem";
  onControl = known && me.control;
  onWorker = known && me.worker;
  controls = lib.filterAttrs (_: member: member.control) members;
  isBootstrap = known && config.cluster.bootstrap != null && config.cluster.bootstrap == host;
  # Derived. cluster.bootstrap is "new". Every other control member is "existing".
  initialClusterState = if isBootstrap then "new" else "existing";
}
