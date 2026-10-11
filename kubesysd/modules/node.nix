{ check }:
{
  imports = [
    (import ./pki.nix { inherit check; })
    (import ./etcd.nix { inherit check; })
    (import ./apiserver.nix { inherit check; })
    (import ./controller-manager.nix { inherit check; })
    (import ./scheduler.nix { inherit check; })
    (import ./addon-manager.nix { inherit check; })
    ./containerd.nix
    (import ./kubelet.nix { inherit check; })
    (import ./proxy.nix { inherit check; })
    (import ./cilium.nix { inherit check; })
  ];
}
