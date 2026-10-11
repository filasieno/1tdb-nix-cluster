# Settings every cluster member shares. Disks, hostId, boot, and WAL paths stay on the node.
{
  sops.defaultSopsFormat = "yaml";
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.age.sshKeyPaths = [ ];
}
