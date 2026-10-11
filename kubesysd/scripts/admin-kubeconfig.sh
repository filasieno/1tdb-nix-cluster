# kubernetes-admin-kubeconfig.sh — write ~/.kube/config for local admins.
#
# The NixOS activation script runs this on every switch. It is idempotent:
# it rewrites the kubeconfig from certificates already on disk and does not
# create a cluster. Nothing happens until /var/lib/kubernetes/secrets/ca.pem
# exists.
#
# For fabio and roberto, an existing ~/.kube/<user>-admin.crt and .key stay
# the kubeconfig identity. Otherwise the shared cluster-admin certificate
# is copied into that home. A user with neither pair is skipped.
#
# The private key is always mode 0600 and owned by that user. kubectl
# rejects a key the group or others can read, and a root-owned key is
# unreadable by the operator, so that operator cannot connect.
#
# Environment, set by the Nix wrapper:
#   KUBERNETES_API_SERVER  apiserver URL, including scheme and port
#
# Wrapped by pkgs.writeShellApplication (errexit, nounset, pipefail; PATH
# includes coreutils).

src=/var/lib/kubernetes/secrets
if [[ -s "$src/ca.pem" ]]; then
  for user in fabio roberto; do
    if ! id "$user" >/dev/null 2>&1; then
      continue
    fi
    home="/home/$user"
    ident="$user-admin"
    install -d -m 0700 -o "$user" -g users "$home/.kube"
    install -m 0644 -o "$user" -g users "$src/ca.pem" "$home/.kube/ca.pem"
    if [[ -s "$home/.kube/$ident.crt" && -s "$home/.kube/$ident.key" ]]; then
      cert="$home/.kube/$ident.crt"
      key="$home/.kube/$ident.key"
      username="$ident"
    elif [[ -s "$src/cluster-admin-key.pem" && -s "$src/cluster-admin.pem" ]]; then
      install -m 0644 -o "$user" -g users "$src/cluster-admin.pem" "$home/.kube/client.pem"
      install -m 0600 -o "$user" -g users "$src/cluster-admin-key.pem" "$home/.kube/client-key.pem"
      cert="$home/.kube/client.pem"
      key="$home/.kube/client-key.pem"
      username="cluster-admin"
    else
      continue
    fi
    chown "$user:users" "$cert" "$key"
    chmod 0644 "$cert"
    chmod 0600 "$key"
    cat >"$home/.kube/config" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    certificate-authority: $home/.kube/ca.pem
    server: $KUBERNETES_API_SERVER
contexts:
- name: local
  context:
    cluster: local
    user: $username
users:
- name: $username
  user:
    client-certificate: $cert
    client-key: $key
current-context: local
EOF
    chown "$user:users" "$home/.kube/config"
    chmod 0600 "$home/.kube/config"
  done
fi
