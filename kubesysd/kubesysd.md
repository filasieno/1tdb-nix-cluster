# kubesysd

kubesysd is a Kubernetes distribution based on Nix and systemd. It installs upstream Kubernetes as separate systemd services. etcd is one of those services, one member per node whose `control` boolean is true. The package is `pkgs.kubernetes`. kubesysd does not build Kubernetes and it does not install k3s. `services.kubernetes.flannel` stays off. Cilium is the CNI.

The public module is `nixosModules.kubesysd`. It imports every component. A node does not import components one by one, and there is no control wrapper or worker wrapper. What runs on a machine is decided by that member's `control` and `worker` booleans.

The node module reads the cluster contract (`cluster.members`, `cluster.kubernetes.*`, `cluster.etcd.*`). It does not define hostnames, disk layout, sops, or OpenBao. The member bundle imports `kubesysd/vault`, which imports `kubesysd/openbao` and `kubesysd/vault-community`. OpenBao runs only when `cluster.vault` is `openbao` and `networking.hostName` is in `cluster.vaultNodes`. Each of those members must have `control = true`.

## Layout

```
flake.nix                         the distribution. One nixosConfiguration per nodes/<name> directory
shared/cluster.nix                contract values, including member booleans
shared/recipients.nix             public age recipients (Fabio's existing ssh-ed25519 key)
shared/member.nix                 sops age settings every member shares
shared/operators.nix              operator accounts
shared/secrets/                   sops files
kubesysd/cluster/module.nix       contract options, rendered to /etc/cluster
kubesysd/cluster/check.nix        the one shape-check library
kubesysd/vault/module.nix         wrapper the member bundle imports
kubesysd/openbao/module.nix       OpenBao on cluster.vaultNodes when cluster.vault is openbao
kubesysd/vault-community/module.nix Vault Community on the one listed hostname
kubesysd/lib.nix                  hostname, booleans, certificate paths
kubesysd/modules/node.nix         imports every component
kubesysd/modules/pki.nix
kubesysd/modules/etcd.nix
kubesysd/modules/apiserver.nix
kubesysd/modules/controller-manager.nix
kubesysd/modules/scheduler.nix
kubesysd/modules/addon-manager.nix
kubesysd/modules/containerd.nix
kubesysd/modules/kubelet.nix
kubesysd/modules/proxy.nix
kubesysd/modules/cilium.nix
kubesysd/scripts/
```

The distribution discovers every directory under `nodes/`. Each configuration is built the same way: `self` is always passed, and `hardware.nix`, `disko.nix`, and `node.nix` come from `nodes/<name>/`. The member module (cluster contract, `shared/cluster.nix`, operators, `shared/member.nix`, sops, `kubesysd/modules/node.nix`, and the vault wrapper) is imported only when that name is a key in `cluster.members`. A node directory that is not listed imports operators only. Hostname lives in `node.nix`, not in `hardware.nix`.

`kubesysd/cluster/check.nix` is the only copy of the shape checks. The distribution passes that `check` into the node module and into the vault wrapper. The wrapper passes it to both implementations. The cluster module does not assert on `services.openbao`. OpenBao's sops assertion is `A vault node must set sops.defaultSopsFile...`. It is active only on a vault node. A control member that is not listed in `cluster.vaultNodes` does not fail that assertion.

## Members

Each member has two booleans. Both may be true. Neither is an enum and there is no role list.

```nix
cluster.members.<hostname> = {
  control = true;
  worker = true;
  address = "127.0.0.1";
};
```

| Boolean | Units |
| --- | --- |
| `control` | etcd, kube-apiserver, controller-manager, scheduler, addon-manager, `cilium-install` |
| `worker` | containerd, kubelet, kube-proxy, Cilium host prep (CNI directory, TCP 4240, UDP 8472) |

A control-only node sets `control = true` and `worker = false`. A worker-only node sets the opposite. At least one must be true. A member that sets both runs the control plane and pods. OpenBao runs only when `cluster.vault` is `openbao` and the hostname is in `cluster.vaultNodes`. `cluster.vaultNodes` lists the member hostnames that run the selected process. Each of those members must have `control = true`.

`lib.nix` is the only place that reads those booleans for Kubernetes:

```nix
onControl = known && me.control;
onWorker = known && me.worker;
controls = lib.filterAttrs (_: member: member.control) members;
```

`networking.hostName` has to be a key in `cluster.members` when the contract is enabled. `address` is the address other members dial. `127.0.0.1` is allowed only while the cluster has a single member. It has to become a reachable address before a second member joins. This repo does not invent that address.

etcd `initialClusterState` is not a member field. It is derived from `cluster.bootstrap`: that control member is `new`, and every other control member is `existing`. A second member cannot evaluate as `new`. On a control member that is not bootstrap, `etcd-member-add.service` runs `etcdctl member add` (idempotent if that name or peer URL is already listed, member or learner) against the other control endpoints, under the etcd lock `cluster/reconcile/etcd-member`, before etcd starts. Add one control member per deploy. The script fails when `initialCluster` lists a peer that is neither this node nor already in the member list, so two new control members in one edit do not join. The sole member does not run that unit.

`cluster.bootstrap` is the hostname allowed to mint the Kubernetes CA and, among vault nodes, the OpenBao listener CA, and the name whose etcd state is `new`. With one control member it defaults to that member. Set it explicitly before a second control member joins. Workers never receive the CA private key.

## Contract

| Option | Meaning | Default |
| --- | --- | --- |
| `cluster.kubernetes.serviceCidr` | Service range | `10.0.0.0/24` |
| `cluster.kubernetes.serviceIp` | `kubernetes` Service, inside that range | `10.0.0.1` |
| `cluster.kubernetes.podCidr` | Pod range, also `services.kubernetes.clusterCidr` | `10.1.0.0/16` |
| `cluster.kubernetes.apiHost` | Name clients use for the API | the only control node, or `cluster.name` |
| `cluster.kubernetes.apiAddress` | Address written into `networking.hosts` for `apiHost` | empty; required only when more than one control member exists |
| `cluster.kubernetes.secretsDir` | PEM directory | `/var/lib/kubernetes/secrets` |
| `cluster.kubernetes.pkiGeneration` | Bump to re-issue leaves without rotating the CA | `1` |
| `cluster.etcd.clientPort` | etcd client | `2379` |
| `cluster.etcd.peerPort` | etcd peer | `2380` |
| `cluster.etcd.initialClusterToken` | first formation token | set in `shared/cluster.nix` |

WAL and snapshot directories are not cluster options. The node sets `kubernetes.etcd.walDirectory` and `kubernetes.etcd.backupDirectory`. A member may use `/var/lib/etcd-wal/wal` and `/data/etcd-backups`. containerd's snapshotter is `kubernetes.containerd.snapshotter`, `overlayfs` or `zfs`. A member sets `zfs` when the containerd state directory is on the ZFS root.

`/etc/cluster/cluster.yaml` is the contract. `/etc/cluster/members/<hostname>.yaml` is one member: `control`, `worker`, `address`, plus, when `control` is true, the derived `initialClusterState` and the etcd URLs. That file gets an `openbao` block only when the member is listed in `cluster.vaultNodes` and `cluster.vault` is `openbao`.

## Where each service runs

`node.nix` imports every module on every member. The booleans turn units on. A node with `worker = false` still imports the kubelet module; the unit stays off.

| Module | Unit | `control` | `worker` |
| --- | --- | --- | --- |
| `pki` | `kubernetes-pki.service` | yes | yes |
| `etcd` | `etcd.service`; `etcd-member-add.service` only when this control member is not bootstrap | yes | |
| `apiserver` | `kube-apiserver.service` | yes | |
| `controller-manager` | `kube-controller-manager.service` | yes | |
| `scheduler` | `kube-scheduler.service` | yes | |
| `addon-manager` | `kube-addon-manager.service` | yes | |
| `containerd` | `containerd.service` | | yes |
| `kubelet` | `kubelet.service` | | yes |
| `proxy` | `kube-proxy.service` | | yes |
| `cilium` | `cilium-install.service` when `control`; CNI directory and firewall when `worker` | yes | yes |

`cloud-controller-manager` is absent.

Boot order when both booleans are true:

```
kubernetes-pki → etcd-member-add (control, not bootstrap) → etcd → kube-apiserver →
  controller-manager, scheduler, addon-manager, kube-proxy, kubelet
kubelet also waits for containerd
cilium-install waits for kube-apiserver, etcd, and kubelet when worker is also true
```

`wants` and `after` only.

## PKI

`modules/pki.nix`. Runs on every member (`networking.hostName` is a key in `cluster.members`). The oneshot writes PEMs under `secretsDir`. Leaf certificates last 10 years. An unchanged stamp does not call openssl, so a rebuild does not rotate them. An existing `ca.pem` is never replaced.

Only the bootstrap control member may mint the CA, and only when `ca.pem` is absent. A control member that is not bootstrap signs its own leaves when `ca.pem` and `ca-key.pem` are already present, copied onto the node or installed from sops at activation. A copied `pki-stamp` that belongs to another host is not fatal: this host's leaves are signed from that CA and the stamp is rewritten. The script does not mint a CA on that node.

The service-account key is created once, on the bootstrap control member, when `service-account-key.pem` is absent. A stamp change or a `pkiGeneration` bump does not regenerate it. A joining control member must already have that pair. It will not create a second signer.

Workers never read `ca-key.pem`. They trust `ca.pem`. A worker may receive that certificate from sops key `kubernetes_ca_cert`, the same attribute control members already use. The secret stays inactive until the key exists in the host sops file. `kubernetes_ca_key` stays on control members only. If `ca.pem` is absent, `kubernetes-pki` fails with one message and does not mint a certificate. If the kubelet and kubelet client certificates are already on disk, they are kept. If they are absent, the oneshot writes a client key, a CSR, and `kubelet-bootstrap.kubeconfig`. It does not write `kube-proxy-client.csr`. It does not invent a bootstrap token.

`kubernetes.kubelet.bootstrapTokenFile` is a string path to a sops secret, or null. When `kubernetes_bootstrap_token` is present in a worker's sops file, the module declares secret `kubernetes-bootstrap-token` and defaults that option to its path. The token value is not set in Nix. Kubelet submits the client CSR through `--bootstrap-kubeconfig` because the NixOS kubelet option `extraConfig` turns on `serverTLSBootstrap` and `rotateCertificates`, and the unit points `--kubeconfig` at a runtime path that does not exist until the certificate is issued. On a control member, the same sops key turns on `services.kubernetes.apiserver.tokenAuthFile`. The file maps the token to group `system:bootstrappers`. That unit is off while the key is absent, so a control member whose sops file does not contain the key still evaluates. The controller-manager signs an approved client CSR: cluster signing is already enabled, and `kubernetes-csr-rbac.service` applies the `system:bootstrappers` and `system:nodes` bindings. It also binds `system:node-proxier` to `system:nodes`, which is what lets kube-proxy authorize with the kubelet client certificate. The bootstrap control member runs `kubelet-serving-csr-approve.timer`. That approves a CSR only when the signer is `kubernetes.io/kubelet-serving`, the CN is `system:node:<name>`, `<name>` is a worker in `cluster.members`, and every IP SAN is that member's address. Client CSRs are not approved by that timer. No token value and no certificate PEM are stored in this repo. Do not copy `ca-key.pem` onto a worker.

Sops secret attributes `kubernetes-ca` (`kubernetes_ca_cert`) and `kubernetes-ca-key` (`kubernetes_ca_key`) stay inactive until those keys exist in the host sops file. The certificate attribute is wired for control members and for workers. The key attribute is wired for control members only. This repo does not contain that ciphertext. While they are absent, the bootstrap host keeps the on-disk CA path.

Other leaf certificates are re-issued when the stamp changes. The stamp is a hash of `pkiGeneration` and the SAN set: this host's name and address, `apiHost`, `cluster.name` when it differs, `apiAddress` when it is set, and each control member address. Bump `pkiGeneration`, or change those names, to re-issue leaves without rotating the CA or the service-account key.

| Name | Who presents it |
| --- | --- |
| `ca` | trust anchor, `CN=kubernetes-ca` |
| `etcd` | etcd server and peer |
| `kube-apiserver` | apiserver serving. SANs: this host's name and address, `apiHost`, `cluster.name` when it differs, `localhost`, `kubernetes`, `kubernetes.default`, `kubernetes.default.svc`, `kubernetes.default.svc.cluster.local`, `127.0.0.1`, service IP, control member addresses, and `apiAddress` when it is set |
| `kube-apiserver-kubelet-client` | apiserver to kubelet |
| `kube-apiserver-proxy-client` | aggregated APIs, `CN=front-proxy-client` |
| `kube-apiserver-etcd-client` | apiserver to etcd |
| `service-account` | token signing |
| `kube-controller-manager` | controller-manager serving |
| `kube-controller-manager-client` | controller-manager to the API |
| `kube-scheduler-client` | scheduler to the API |
| `kubelet` | kubelet serving, `CN=system:node:<hostname>` |
| `kubelet-client` | kubelet to the API, `O=system:nodes` |
| `kube-proxy-client` | kube-proxy to the API, only when this member is both control and worker. A worker that is not control uses the kubelet client certificate instead |
| `kube-addon-manager` | addon manager, `O=system:masters` |
| `cluster-admin` | admin kubeconfig, `O=system:masters` |

Control members also require `ca-key.pem`. Workers do not. Activation writes `~/.kube/config` for `fabio` and `roberto` once `ca.pem` exists. The server URL is `services.kubernetes.apiserverAddress` (`https://<apiHost>:6443`).

## etcd

`modules/etcd.nix`. One member per node with `control = true`. Data is `/var/lib/etcd`. Listeners follow `member.address`. A loopback member listens on `127.0.0.1` only. Any other address also opens the client and peer ports on the firewall.

`initialClusterState` is derived from `cluster.bootstrap`. When one control member exists, `cluster.bootstrap` defaults to that member's hostname, so its state is `new` and it does not run `etcd-member-add`. Every other control member is `existing`. Before its etcd starts, the oneshot adds it to the cluster that is already running. `initialCluster` lists every control member as `name=https://address:peerPort`.

Add one control member per deploy. If `initialCluster` lists a peer that is neither this node nor already in the member list, `etcd-member-add.sh` fails and etcd does not start. Two new control members in one edit do not silently mis-join. That check is not a Nix assertion, so the single member still evaluates.

The unit waits for the PKI, and for `etcd-member-add` when this member is not bootstrap. It does not wait for OpenBao. When `backupDirectory` is set, a daily timer keeps the newest 14 snapshots, using the apiserver etcd client certificate against `https://127.0.0.1:2379`.

Member count stays odd: 1, then 3, then 5.

## kube-apiserver

`modules/apiserver.nix`. `control` only. This is the only process that talks to etcd. `--allow-privileged` is on because Cilium loads BPF and mounts host paths.

etcd servers are every control member's `https://address:clientPort`. The serving certificate, the kubelet client certificate, the front-proxy client certificate, and the service-account key come from the PKI. The firewall opens TCP 6443.

With one control node, `apiHost` is that node's name and `cluster.kubernetes.apiAddress` is not required. With several, `apiHost` is `cluster.name`, and the operator must set `cluster.kubernetes.apiAddress` to a non-empty address. That address is written into `networking.hosts` for `apiHost`. This repo does not invent it.

Bootstrap token auth is a token file, not a Secret. When `kubernetes_bootstrap_token` exists in the control member's sops file, `kubernetes-bootstrap-token.service` writes `/run/kubernetes/bootstrap-token-auth.csv` and `services.kubernetes.apiserver.tokenAuthFile` points at it. The CSV maps the token to user `system:bootstrap:kubelet` and group `system:bootstrappers`. The token value is not in git. While the key is absent the option stays null, and a single-node control plane still builds. Secret-based tokens are not used, so `bootstrapsigner` and `tokencleaner` stay off.

## kube-controller-manager

`modules/controller-manager.nix`. `control` only. One binary runs the built-in controllers. Leader election leaves a single active replica when more than one control node exists.

The cluster CA is the CSR signer (`--cluster-signing-cert-file` and `--cluster-signing-key-file`). The same service-account key signs tokens the apiserver verifies. `services.kubernetes.clusterCidr` is the pod CIDR this process allocates to nodes.

`kubernetes-csr-rbac.service` applies the bootstrap ClusterRoleBindings, including `system:node-proxier` bound to `system:nodes`. `kubelet-serving-csr-approve.timer` runs only on `cluster.bootstrap`. It uses kubectl with the cluster-admin kubeconfig against `https://127.0.0.1:6443`, under the etcd lock `cluster/reconcile/kubelet-serving-csr`. It approves one CSR at a time, and only a kubelet serving CSR whose CN is `system:node:<name>` for a worker in `cluster.members` whose IP SANs are that member's address.

## kube-scheduler

`modules/scheduler.nix`. `control` only. Binds pods to nodes. Leader election keeps one active scheduler.

## kube-addon-manager

`modules/addon-manager.nix`. `control` only. Reconciles addon manifests shipped with `pkgs.kubernetes`. The kubeconfig is built from the addon-manager client certificate and `apiserverAddress`. Cilium is installed by its own unit; the addon manager does not carry that chart.

## containerd

`modules/containerd.nix`. The unit runs when `worker` is true. The kubelet speaks CRI to this socket. The runtime is crun, with an absolute `BinaryName`, and cgroup driver `systemd`.

The snapshotter is `overlayfs` or `zfs`. The default is `overlayfs`. A ZFS root sets `kubernetes.containerd.snapshotter = "zfs"` on the node, and the module creates the snapshotter directory containerd skips when it is missing. The transfer unpack list names the same snapshotter.

A member whose containerd state directory is on ZFS:

```nix
{ kubernetes.containerd.snapshotter = "zfs"; }
```

## kubelet

`modules/kubelet.nix`. The unit runs when `worker` is true. `control = true` does not start it by itself. The client certificate is `system:node:<hostname>` in `system:nodes`. CNI binaries come from `cni-plugins`; Cilium writes the network config later. The firewall opens TCP 10250.

When `control` is also true, the kubelet uses the leaves this host signed and waits for the local apiserver. A worker that is not a control member does not set those leaf paths. It waits for the PKI and containerd, then either uses client certificates already on disk or starts with `--bootstrap-kubeconfig` and `--cert-dir=/var/lib/kubelet/pki` so the controller-manager can sign the client CSR. The issued client certificate lands at `kubelet-client-current.pem`. Serving certificates are requested with `serverTLSBootstrap` and approved by the bootstrap member's timer, then signed by the controller-manager. It dials `apiserverAddress`.

## kube-proxy

`modules/proxy.nix`. The unit runs when `worker` is true. A control member that is also a worker keeps the signed `kube-proxy-client` leaf, because the bootstrap PKI already mints it. A worker that is not a control member does not get that leaf and does not write `kube-proxy-client.csr`. kube-proxy there starts once `kubelet-client-current.pem` exists, or once `kubelet-client.pem` and its key are already on disk, and uses that client certificate. `system:node-proxier` is bound to `system:nodes` so that certificate can authorize. Cilium runs with `kubeProxyReplacement` off, so this process owns ClusterIP and NodePort rules. That is the path Istio can intercept. Turning Cilium kube-proxy replacement on later means disabling this module in the same change.

## Cilium

`modules/cilium.nix`. Flannel is forced off on any member. The NixOS CNI directory is forced off when `worker` is true, so Cilium is the writer of `/etc/cni/net.d`. The chart is `https://helm.cilium.io/cilium-1.20.2.tgz`.

`cilium-install.service` runs when `control` is true, after the apiserver and etcd, and after the kubelet when `worker` is also true. It takes an etcd lock `cluster/reconcile/cilium`, then `helm upgrade --install`. Helm talks to `https://127.0.0.1:6443` with the cluster-admin kubeconfig, because `nss-myhostname` answers the machine name with `127.0.0.2`, which is not on the apiserver certificate.

The operator runs one replica on a single control node and two replicas when the cluster has two or more control nodes. Workers open TCP `4240` (Cilium health) and UDP `8472` (VXLAN).

Istio is not installed here. These values leave room for it:

| Value | Setting | What it leaves for Istio |
| --- | --- | --- |
| `kubeProxyReplacement` | `false` | kube-proxy keeps ClusterIP. Istio intercepts that path. |
| `ipam.mode` | `kubernetes` | Pod CIDRs come from the API, same range as `cluster.kubernetes.podCidr`. |
| `routingMode` / `tunnelProtocol` | `tunnel` / `vxlan` | Pod traffic crosses a hosted network without L2 or BGP. |
| `socketLB.hostNamespaceOnly` | `true` | Socket LB stays in the host namespace, so a sidecar in the pod is still on the path. |
| `cni.exclusive` | `false` | Istio's CNI plugin can chain beside Cilium. |
| `bpf.masquerade` | `false` | Masquerade stays with kube-proxy. |
| `l7Proxy` | `false` | Cilium does not terminate L7. |
| `envoy.enabled` | `false` | Cilium's Envoy stays out. Istio owns L7. |
| `gatewayAPI.enabled` | `false` | A later Istio Gateway is the north-south API. |
| `ingressController.enabled` | `false` | Cilium does not take ingress. |
| `envoyConfig.enabled` | `false` | Cilium does not install Envoy listener CRDs. |

## OpenBao

Not a Kubernetes module. The member bundle imports `kubesysd/vault`, which imports `kubesysd/openbao` and `kubesysd/vault-community`. The distribution passes `lib.check` into the vault wrapper. The wrapper passes it to both implementations. OpenBao runs only when `cluster.vault` is `openbao` and `networking.hostName` is in `cluster.vaultNodes`. Each of those members must have `control = true`. A control member that is not listed does not run OpenBao, does not open ports 8201/8202, does not get the OpenBao sops secrets, and does not fail the OpenBao sops assertion. The assertion message is `A vault node must set sops.defaultSopsFile...`. It is active only on a vault node. The cluster module does not reach into `services.openbao`.

Loopback uses `http://127.0.0.1:8200` and `http://127.0.0.1:8202`. Any other address uses `https://<address>:8201` and `https://<address>:8202`. The listener certificate for a non-loopback address includes that address. `openbao-tls.sh` describes OpenBao. `retry_join` lists the other `cluster.vaultNodes` entries. When a listed peer is not loopback, the stanza sets `leader_ca_cert_file` to `/var/lib/openbao/tls/ca.crt` (OpenBao reads the leader CA at start; the PEM is not known at evaluation). Loopback peers speak HTTP and do not set it.

Among vault nodes, `cluster.bootstrap` is who may mint the OpenBao listener CA, and only when `ca.crt` is absent. A vault node that is not bootstrap fails closed if `ca.crt` is missing and does not generate one. Copy `ca.crt` from the bootstrap member onto the next vault node, and copy `ca.key` as well when that node must sign its own listener certificate. A control member that is not listed does not need those files. The same files can be installed from sops keys `openbao_ca_cert` and `openbao_ca_key` once those keys exist in the host sops file. Those attributes stay inactive until then. This repo does not contain that ciphertext. The recovery age recipient stays `cluster.openbao.recoveryRecipient` from `shared/recipients.nix`.

`OPENBAO_BOOTSTRAP` is `1` only when `cluster.bootstrap` equals the hostname. The init unit exists only on a vault node. A joiner's unit script does not call initialization. It waits until `bao status` reports `initialized=true`. `retry_join` lists the other `cluster.vaultNodes` entries. If OpenBao is not initialized yet, the unit fails and systemd retries. A joiner does not create a second Raft cluster.

The Azure vault name and key name come from the cluster contract. The client secret stays in sops. The recovery age recipient is `cluster.openbao.recoveryRecipient`, set from `shared/recipients.nix` to Fabio's existing ssh-ed25519 public key. It is not a new secret and it is not hard-coded in the OpenBao template.

## A second member

A new node is a directory `nodes/<name>/` (`hardware.nix`, `disko.nix`, `node.nix` with the hostname) plus one `cluster.members.<name>` entry. The distribution picks the directory up. Importing the member module is automatic once the name is in `cluster.members`. etcd `initialClusterState` is not set on that entry. It is derived from `cluster.bootstrap`.

Token auth and the kubelet serving CSR approver are in this derivation. A control member accepts the bootstrap token when `kubernetes_bootstrap_token` is in that host's sops file: `tokenAuthFile` maps it to `system:bootstrappers`. `kubelet-serving-csr-approve.timer` on `cluster.bootstrap` approves a serving CSR only for a worker in `cluster.members` whose CN is `system:node:<name>` and whose IP SANs are that member's address. There is no separate manual approve step. The token value is not written here.

What the operator still sets. This repo does not invent an address, a token, or ciphertext.

Worker:

- The `nodes/<name>/` directory.
- One `cluster.members.<name>` entry (`worker = true`, and `control` false when the node is only a worker) with that node's address.
- The existing member's reachable address. `127.0.0.1` is allowed only while the cluster has a single member.
- The sops token path. Add `kubernetes_bootstrap_token` to the worker sops file and to each control member's sops file. On the worker, `kubernetes.kubelet.bootstrapTokenFile` then defaults to `/run/secrets/kubernetes-bootstrap-token`. `kubernetes_ca_cert` may be added to the worker sops file so `ca.pem` does not have to be copied by hand. Do not add `kubernetes_ca_key`, the service-account key, or the OpenBao CA key.

Control:

- The `nodes/<name>/` directory.
- One `cluster.members.<name>` entry with `control = true` and that node's address.
- `cluster.bootstrap`, naming the member that already minted the CA.
- `cluster.kubernetes.apiAddress`. No address is filled in here.
- An age recipient on the new host sops file. Use Fabio's existing key, the same recipient as `cluster.openbao.recoveryRecipient`.
- Azure seal secrets (`azure_tenant_id`, `azure_client_id`, `azure_client_secret`) when this host is a vault node: `cluster.vault` is `openbao` and the hostname is in `cluster.vaultNodes`, or it is the single Vault Community node. The client secret stays in sops. A control member who is not a vault node does not get those secrets.
- CA and service-account material. Copy `ca.pem`, `ca-key.pem`, `service-account.pem`, and `service-account-key.pem` from the bootstrap member, or add `kubernetes_ca_cert` and `kubernetes_ca_key` to that host's sops file. The joining control signs its own leaves only when both CA files are already present. It does not mint a second CA or a second service-account key. There is no ciphertext to commit.
- Copy OpenBao `ca.crt` and `ca.key` from `/var/lib/openbao/tls/` on the bootstrap member, or add `openbao_ca_cert` and `openbao_ca_key` in sops once those keys exist, only when this hostname is also listed in `cluster.vaultNodes` and `cluster.vault` is `openbao`. Among vault nodes, `cluster.bootstrap` is who may mint that listener CA. A control member that is not listed does not run OpenBao and does not copy that CA.
- One control member per deploy.

etcd membership stays an odd count (1, then 3, then 5).

## Cloud controller manager

This flake does not run `cloud-controller-manager`. Nothing here calls a hosting provider's API. Installing it later means `--cloud-provider=external` on the apiserver, the controller-manager, and the kubelet, plus that provider's binary. Until a provider is chosen, the unit stays out, because an unconfigured manager blocks node initialization.
