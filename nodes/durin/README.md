# Durin

Single control-plane and worker node. Cilium is the CNI and the service datapath. kube-proxy is not installed. Istio is not installed by this flake; Flux installs it later.

## Addresses

`lan1` is the Intel I210 whose permanent MAC is `90:5a:08:c2:f9:56`. It has `192.168.1.230/24` via `192.168.1.254`. DHCP is off. The firewall opens published ports only on `lan1`.

`lan1-ready.service` checks that this address is configured. sshd, the API server, the kubelet, and Vault require that unit. If the MAC rename does not apply, those services do not start, and the firewall rules are not left matching an interface that does not exist.

On this host, `k3s.1tdb.io` resolves to `192.168.1.230`. The website name is `www.1tdb.io`, and it is not on the API certificate. Control-plane kubeconfigs use `https://127.0.0.1:6443`. Admin kubeconfigs use `https://k3s.1tdb.io:6443`.

## Cilium replaces kube-proxy

`cilium-install.service` installs chart 1.20.2 after the API server and the kubelet are up. The values in `nix/commands.nix` set:

| Value | Why |
| --- | --- |
| `kubeProxyReplacement: true` | Cilium BPF implements ClusterIP and masquerade. There is no kube-proxy unit. |
| `k8sServiceHost` / `k8sServicePort` | `192.168.1.230` and `6443`. The agent and operator reach the API without a ClusterIP. |
| `waitForKubeProxy: false` | The chart must not block on a kube-proxy iptables rule. |
| `devices: lan1` | BPF attaches only to the pinned NIC, not to the BMC USB gadget. |
| `socketLB.enabled` and `socketLB.hostNamespaceOnly` | Socket load balancing stays in the host network namespace. A future Istio sidecar in a pod still sees the original destination. |
| `cni.exclusive: false` | Cilium does not rename a CNI config that Istio adds later. |
| `bpf.masquerade` and `enableIPv4Masquerade` | Pod egress is masqueraded on `lan1` without kube-proxy. |
| `gatewayAPI.enabled: false`, `envoy.enabled: false`, `l7Proxy: false` | Cilium does not own Gateway resources or run its own Envoy. Istio will. |

Do not turn `gatewayAPI.enabled` on when Flux installs Istio. Two controllers would both program `Gateway` objects.

## Istio, installed later with Flux

Flux can install Istio. This node does not. Bootstrap Flux against the API after Cilium is Ready, then let Flux apply, in order:

1. Gateway API standard CRDs, v1.6.0. Istio 1.31 expects that set.
2. The `istio/base` Helm chart, then `istiod`, one replica. Charts are published at `https://blob.istio.io/istio-release/charts`.
3. The Gateway below, in namespace `istio-ingress`.

Do not put that manifest in `addons/`. `kube-addons` applies that directory on every start, and the Gateway CRD will not exist until Flux has installed it.

`hostNetwork: true` makes Envoy bind `0.0.0.0` on each listener port. The Gateway API has no field that selects `192.168.1.230`. The packet arrives on `lan1` because that is the only card with this address, the upstream forward targets it, and the firewall allows the port only there.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: edge-gw-options
  namespace: istio-ingress
data:
  deployment: |
    spec:
      template:
        spec:
          hostNetwork: true
          dnsPolicy: ClusterFirstWithHostNet
  service: |
    spec:
      type: ClusterIP
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge
  namespace: istio-ingress
spec:
  gatewayClassName: istio
  infrastructure:
    parametersRef:
      group: ""
      kind: ConfigMap
      name: edge-gw-options
  listeners:
  - name: http
    port: 8080
    protocol: HTTP
    hostname: "www.1tdb.io"
    allowedRoutes:
      namespaces:
        from: All
  - name: https
    port: 7443
    protocol: HTTPS
    hostname: "k3s.1tdb.io"
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        group: ""
        name: k3s-1tdb-tls
    allowedRoutes:
      namespaces:
        from: All
  - name: telepresence
    port: 7778
    protocol: UDP
    allowedRoutes:
      namespaces:
        from: All
```

Istio still creates a Service named `edge-istio`. With `type: ClusterIP` it has no load-balancer address. Clients use `192.168.1.230` and the listener port. The TLS Secret `k3s-1tdb-tls` has to exist before the HTTPS listener is programmed. A route's `parentRef` selects this Gateway.

In a datacenter, change the HTTP and HTTPS ports to 80 and 443, open those ports on `lan1`, and add `NET_BIND_SERVICE` to the `istio-proxy` container in the same ConfigMap. Ask the datacenter to route one public address to MAC `90:5a:08:c2:f9:56`. That address is configured on the NIC. It is not a virtual IP.

## Vault

Vault Community auto-unseals with the Azure Key Vault seal named in `nix/azure.nix`. The local listener is `127.0.0.1:8200` without TLS. The network listener is `192.168.1.230:8201` with TLS.

The listener certificate includes `durin`, localhost, `127.0.0.1`, `192.168.1.230`, and `k3s.1tdb.io`. `vault-tls` reissues it when that list changes. `vault-init` returns only when Vault is unsealed. If it is still sealed, the unit restarts `vault.service` once and waits again. Recovery is one share, age-encrypted so both admins can read it.

### The one secret, sealed to the TPM

Tenant id, client id, vault name, and key name are identifiers and sit in `nix/azure.nix`. The client secret is the only value that must stay private, and it is the only thing Vault needs that the flake cannot state in clear. It is stored in `secrets/azure-client-secret.cred`, a systemd encrypted credential sealed to durin's TPM 2.0. Only that chip can open it, which is what makes a public repo safe to hold it. At start, `LoadCredentialEncrypted=` in `vault.service` has systemd unseal it into `$CREDENTIALS_DIRECTORY`, readable by the `vault` user alone, and the wrapper exports it as `AZURE_CLIENT_SECRET`. Nothing is copied onto the host outside the flake; a reinstall needs no extra files.

Two sealing choices matter. `--with-key=tpm2` alone, because the default also mixes in `/var/lib/systemd/credential.secret`, a per-install host key that a reinstall would regenerate. An empty PCR list, so a firmware or kernel update cannot lock Vault out; the trade is that any OS booted on this board can ask the TPM to unseal it, the same exposure as root on the host. PCR 7 binding is a later step once Secure Boot is on.

Sealing happens on durin, once, and after that only when the secret rotates or the TPM is cleared. The clear text for re-sealing lives in `secrets/secrets.yaml`, sops-encrypted to the admin age key:

```sh
sops -d --extract '["azure_client_secret"]' nodes/durin/secrets/secrets.yaml \
  | ssh durin sudo vault-seal-credential > nodes/durin/secrets/azure-client-secret.cred
git add nodes/durin/secrets/azure-client-secret.cred && git commit -m "feat(durin): seal the Azure client secret" && git push
ssh durin sudo nixos-rebuild switch --flake github:filasieno/1tdb-nix-cluster#durin
```

`vault-seal-credential` refuses to run without a usable TPM (`systemd-creds has-tpm2`) and verifies the round trip through the chip before printing. Until the file exists the flake evaluates with a warning, the system boots, sshd and Kubernetes come up, and only `vault.service` fails with a message pointing here. A TPM clear or a board swap means running the three lines again.

### Azure side of the seal

Verified 2026-10-11. Key Vault `BootstrapKeys` (resource group `durin-keys`) is in RBAC mode with soft delete and purge protection. Key `vault-unseal` is RSA with `wrapKey` and `unwrapKey`, enabled, no expiry. The service principal `durin-vault-unseal` (app `f4619c34-…`) holds `Key Vault Crypto User` on that vault, which is what the seal needs. Its client secret `durin-vault-unseal-2026-10` expires 2028-10-11; the older `rbac` credential stays valid until the reinstall is up, then delete it:

```sh
az ad app credential delete --id f4619c34-21da-4a3a-b667-524e6ded923a --key-id 8f853aa0-384e-4b49-8f54-abbb7fc4f5c7
```

To rotate the secret again, update the admin copy, then re-seal with the three lines above:

```sh
NEW=$(az ad app credential reset --id f4619c34-21da-4a3a-b667-524e6ded923a --append --years 2 --display-name durin-vault-unseal-$(date +%Y-%m) --query password -o tsv)
sops set nodes/durin/secrets/secrets.yaml '["azure_client_secret"]' "\"$NEW\""
```

### Who can read `secrets/secrets.yaml`

One age recipient, listed in the repo root `.sops.yaml`: Fabio's admin key, derived from `~/.ssh/ffilasieno` with `ssh-to-age` and stored in `~/Library/Application Support/sops/age/keys.txt` on the Mac (`~/.config/sops/age/keys.txt` is a symlink to it). The host has no age key. After adding or removing a recipient run `sops updatekeys nodes/durin/secrets/secrets.yaml` with an identity that can already open the file.

## Disk

The mirrored PM893 pair is the root pool. The Optane pool is the etcd WAL. The 990 PRO holds `/data` and `data/containerd`, mounted at `/var/lib/containerd`. On a pool created before that dataset existed, `containerd-dataset.service` creates it before the mount. On a host that already ran containerd from the SATA mirror, the zfs snapshotter left `rpool/var/<id>` datasets with mountpoints under the old path. Destroy those before the first boot with this layout, or they mount over the new dataset.

## Installing

Both routes wipe the four disks named in `nix/disko.nix`: the two PM893, the Optane, and the 990 PRO. Everything on them is gone, including the current Vault and etcd. Commit and push first: Nix copies only tracked files, and the console route fetches from GitHub. Passwords are locked for every account, so the BMC console is a view of the installed system, never a login into it; if `lan1-ready` fails on first boot, sshd does not start, and the way back in is the installer again.

### From the installer console

The repo is public, so the flake is fetched straight from GitHub. The installer's network comes up with DHCP on both I210 ports; the static address is set by hand so the result is the one the NAT gateway forwards to:

```sh
ip link set eno1 up
ip addr add 192.168.1.230/24 dev eno1
ip route add default via 192.168.1.254
echo "nameserver 192.168.1.254" > /etc/resolv.conf

nixos-install --no-root-passwd --flake github:filasieno/1tdb-nix-cluster#durin
reboot
```

`--no-root-passwd` skips the password prompt. A password typed there is discarded anyway: `users.mutableUsers = false` rewrites `/etc/shadow` from the configuration at every activation and every account stays locked. The first boot mints new SSH host keys, so expect a `known_hosts` change on the next `ssh durin`.

### With nixos-anywhere

From a machine with Nix (this Mac has it at `/nix`; `. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh` puts it on PATH). The build cannot happen on macOS for an x86_64-linux system, so the closure is built on durin inside the installer:

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake .#durin \
  --build-on remote \
  --target-host fabio@192.168.1.230 \
  --ssh-port 2222 \
  --copy-host-keys
```

After kexec the installer listens on port 22, which is nixos-anywhere's default for that phase. `--copy-host-keys` keeps the SSH host keys. nixos-anywhere exports the ZFS pools before reboot, so the `4e8025bc` host id imports them on first boot. On 2026-10-11 the kexec image came up without an address on `eno1`; the fix was the four `ip` lines above typed on the console, after which nixos-anywhere connected on its own.

### First boot

`kubernetes-pki` mints a new CA, `cilium-install` installs the chart, sshd answers on 2222 for the admin keys in `nix/admins.nix`. If `secrets/azure-client-secret.cred` is in the flake, `vault-init` initializes Vault against the Azure key and writes `recovery.age`; if it is absent, seal it as described under Vault and switch. Flux and Istio come after that.

## Still outside this repo

The FASTGate DHCP reservation already holds `192.168.1.230` for one MAC. TCP `6443` and `2222` are forwarded to that address. Checked on 2026-10-11: `www.1tdb.io` and `k3s.1tdb.io` are `93.55.234.106`; port 2222 there answers `SSH-2.0-OpenSSH_10.5`, and port 6443 presents the API certificate. The apex name `1tdb.io` is not used. TCP `8080`, `7443`, and UDP `7778` are the Istio listeners Flux will install.
