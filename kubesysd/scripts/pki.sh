# kubernetes-pki.sh — issue cluster certificates.
#
# kubernetes-pki.service runs this before etcd, kube-apiserver, and kubelet.
#
# Only the bootstrap control member may mint the CA, and only when ca.pem
# is absent. An existing ca.pem is never replaced.
#
# The service-account key is created once, on the bootstrap control member,
# when service-account-key.pem is absent. A stamp change or a pkiGeneration
# bump does not regenerate it.
#
# A control member that is not bootstrap signs its own leaves when ca.pem
# and ca-key.pem are already present (copied onto the node, or installed
# from sops at activation). A copied pki-stamp that names another host is
# not a failure: this host's leaves are signed from that CA and the stamp
# is rewritten. This script does not mint a CA there.
#
# Workers never read ca-key.pem. They trust ca.pem. That certificate may be
# installed from sops key kubernetes_ca_cert. If ca.pem is absent the script
# fails with one message and does not mint a CA. If the kubelet client
# certificate is absent, the script writes a client key, a CSR, and a
# bootstrap kubeconfig. It does not write a kube-proxy client CSR. Kubelet
# submits its client CSR when kubernetes.kubelet.bootstrapTokenFile points
# at a sops secret. The token value is not set here. kube-proxy on this
# worker uses the kubelet client certificate after it is issued.
#
# Other leaf certificates are re-issued when KUBERNETES_PKI_STAMP changes.
# That stamp is a hash of cluster.kubernetes.pkiGeneration and the SAN set
# (this host's name and address, apiHost, cluster.name when it differs,
# and each control member address).
#
# Environment, set by the Nix wrapper:
#   KUBERNETES_SECRETS_DIR       directory for the PEM files
#   KUBERNETES_HOSTNAME          node name placed in server certificates
#   KUBERNETES_BOOTSTRAP         1 only on the bootstrap control member
#   KUBERNETES_ROLE_CONTROL      1 when this member's control boolean is true
#   KUBERNETES_ROLE_WORKER       1 when this member's worker boolean is true
#   KUBERNETES_PKI_STAMP         generation + SAN hash written to pki-stamp
#   KUBERNETES_APISERVER_SANS    subjectAltName for the API server certificate
#   KUBERNETES_ETCD_SANS         subjectAltName for the etcd certificate
#   KUBERNETES_KUBELET_SANS      subjectAltName for the kubelet server certificate
#   KUBERNETES_CONTROLLER_SANS   subjectAltName for the controller-manager certificate
#   KUBERNETES_API_SERVER        apiserver URL written into the bootstrap kubeconfig
#   KUBERNETES_BOOTSTRAP_TOKEN_FILE
#                                absolute path of a sops secret holding the kubelet
#                                bootstrap token, or empty when that option is unset
#   KUBERNETES_REQUIRED          newline-separated files that must already exist
#                                for the fast path. Workers omit ca-key.pem.
#
# Wrapped by pkgs.writeShellApplication (errexit, nounset, pipefail; PATH
# includes openssl and coreutils).

dir=$KUBERNETES_SECRETS_DIR
host=$KUBERNETES_HOSTNAME
bootstrap=${KUBERNETES_BOOTSTRAP:-0}
control=${KUBERNETES_ROLE_CONTROL:-0}
worker=${KUBERNETES_ROLE_WORKER:-0}

stamp_now=""
if [[ -s $dir/pki-stamp ]]; then
  stamp_now=$(cat "$dir/pki-stamp")
fi

file_ok() {
  [[ -s $dir/$1 ]]
}

collect_missing() {
  local name
  missing=()
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    file_ok "$name" || missing+=("$name")
  done <<EOF
$KUBERNETES_REQUIRED
EOF
}

# Worker-only. Trust ca.pem. Do not open ca-key.pem, even if a copy was left here.
if [[ $control != 1 ]]; then
  if [[ ! -s $dir/ca.pem ]]; then
    echo "kubernetes-pki: ca.pem is absent. Install kubernetes_ca_cert from this host's sops file, or copy the cluster CA certificate to ${dir}/ca.pem. This worker does not read ca-key.pem and will not mint a certificate." >&2
    exit 1
  fi

  install -d -m 0750 -o root -g kubernetes "$dir"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  client_ready=1
  for name in kubelet kubelet-client; do
    file_ok "${name}.pem" && file_ok "${name}-key.pem" || client_ready=0
  done

  if [[ $client_ready == 1 ]]; then
    cat >"$tmp/kubelet.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    certificate-authority: ${dir}/ca.pem
    server: ${KUBERNETES_API_SERVER}
contexts:
- name: local
  context:
    cluster: local
    user: kubelet
current-context: local
users:
- name: kubelet
  user:
    client-certificate: ${dir}/kubelet-client.pem
    client-key: ${dir}/kubelet-client-key.pem
EOF
    install -m 0440 -o root -g kubernetes "$tmp/kubelet.kubeconfig" "$dir/kubelet.kubeconfig"
    printf '%s\n' "$KUBERNETES_PKI_STAMP" >"$tmp/pki-stamp"
    install -m 0444 -o root -g kubernetes "$tmp/pki-stamp" "$dir/pki-stamp"
    exit 0
  fi

  ensure_key() {
    local name=$1
    if [[ ! -s $dir/${name}-key.pem ]]; then
      openssl genrsa -out "$tmp/${name}-key.pem" 2048
      install -m 0440 -o root -g kubernetes "$tmp/${name}-key.pem" "$dir/${name}-key.pem"
    fi
  }

  write_csr() {
    local name=$1
    local subj=$2
    shift 2
    ensure_key "$name"
    openssl req -new -key "$dir/${name}-key.pem" -subj "$subj" -out "$tmp/${name}.csr" "$@"
    install -m 0444 -o root -g kubernetes "$tmp/${name}.csr" "$dir/${name}.csr"
  }

  write_csr kubelet-client "/O=system:nodes/CN=system:node:${host}"
  write_csr kubelet "/CN=system:node:${host}" -addext "subjectAltName=${KUBERNETES_KUBELET_SANS}"

  if [[ -n ${KUBERNETES_BOOTSTRAP_TOKEN_FILE} ]]; then
    cat >"$tmp/kubelet-bootstrap.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    certificate-authority: ${dir}/ca.pem
    server: ${KUBERNETES_API_SERVER}
contexts:
- name: local
  context:
    cluster: local
    user: kubelet-bootstrap
current-context: local
users:
- name: kubelet-bootstrap
  user:
    tokenFile: ${KUBERNETES_BOOTSTRAP_TOKEN_FILE}
EOF
  else
    cat >"$tmp/kubelet-bootstrap.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    certificate-authority: ${dir}/ca.pem
    server: ${KUBERNETES_API_SERVER}
contexts:
- name: local
  context:
    cluster: local
    user: kubelet-bootstrap
current-context: local
users:
- name: kubelet-bootstrap
  user: {}
EOF
    echo "kubernetes-pki: wrote kubelet client key and CSR in ${dir}. kubernetes.kubelet.bootstrapTokenFile is unset, so kubelet cannot submit the CSR until that option points at a sops secret. No token value is set here." >&2
  fi
  install -m 0440 -o root -g kubernetes "$tmp/kubelet-bootstrap.kubeconfig" "$dir/kubelet-bootstrap.kubeconfig"
  exit 0
fi

collect_missing
if [[ $stamp_now == "$KUBERNETES_PKI_STAMP" && ${#missing[@]} -eq 0 ]]; then
  exit 0
fi

install -d -m 0750 -o root -g kubernetes "$dir"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [[ ! -s $dir/ca.pem ]]; then
  if [[ $bootstrap != 1 ]]; then
    echo "kubernetes-pki: ca.pem is absent. Only the bootstrap control member may mint the CA." >&2
    echo "Copy ca.pem and ca-key.pem onto this node, or add kubernetes_ca_cert and kubernetes_ca_key to this host's sops file so activation installs them." >&2
    exit 1
  fi
  openssl genrsa -out "$tmp/ca-key.pem" 4096
  openssl req -x509 -new -key "$tmp/ca-key.pem" -sha256 -days 3650 \
    -subj "/CN=kubernetes-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$tmp/ca.pem"
  install -m 0440 -o root -g kubernetes "$tmp/ca-key.pem" "$dir/ca-key.pem"
  install -m 0444 -o root -g kubernetes "$tmp/ca.pem" "$dir/ca.pem"
fi

if [[ ! -s $dir/ca-key.pem ]]; then
  if [[ $bootstrap == 1 ]]; then
    echo "kubernetes-pki: ca.pem is present but ca-key.pem is not. Refusing to rotate the CA." >&2
  else
    echo "kubernetes-pki: ca-key.pem is absent. This control member will not mint a CA." >&2
    echo "Copy ca-key.pem onto this node, or add kubernetes_ca_key to this host's sops file so activation installs it." >&2
  fi
  exit 1
fi

# ca.pem and ca-key.pem are present. Sign this host's leaves.
# A stamp copied from another host is ignored.

if [[ -s $dir/service-account-key.pem && -s $dir/service-account.pem ]]; then
  :
elif [[ -s $dir/service-account-key.pem || -s $dir/service-account.pem ]]; then
  echo "kubernetes-pki: service-account files are incomplete. Refusing to regenerate the service-account key." >&2
  exit 1
elif [[ $bootstrap == 1 ]]; then
  openssl genrsa -out "$tmp/service-account-key.pem" 2048
  openssl req -new -x509 \
    -key "$tmp/service-account-key.pem" \
    -sha256 \
    -days 3650 \
    -subj "/CN=system:service-account-signer" \
    -out "$tmp/service-account.pem"
  install -m 0444 -o root -g kubernetes "$tmp/service-account.pem" "$dir/service-account.pem"
  install -m 0440 -o root -g kubernetes "$tmp/service-account-key.pem" "$dir/service-account-key.pem"
else
  echo "kubernetes-pki: the service-account key is created once on the bootstrap member. Copy service-account.pem and service-account-key.pem here. This node will not create another." >&2
  exit 1
fi

client_ext=$tmp/client.ext
cat >"$client_ext" <<'EOF'
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF

write_server_ext() {
  local path=$1
  local sans=$2
  local usage=${3:-serverAuth}
  cat >"$path" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=${usage}
subjectAltName=${sans}
EOF
}

write_server_ext "$tmp/apiserver.ext" "$KUBERNETES_APISERVER_SANS"
write_server_ext "$tmp/etcd.ext" "$KUBERNETES_ETCD_SANS" "serverAuth,clientAuth"
write_server_ext "$tmp/kubelet.ext" "$KUBERNETES_KUBELET_SANS"
write_server_ext "$tmp/controller.ext" "$KUBERNETES_CONTROLLER_SANS"

sign_cert() {
  local name=$1
  local subj=$2
  local extfile=$3
  openssl genrsa -out "$tmp/${name}-key.pem" 2048
  openssl req -new -key "$tmp/${name}-key.pem" -subj "$subj" -out "$tmp/${name}.csr"
  openssl x509 -req \
    -in "$tmp/${name}.csr" \
    -CA "$dir/ca.pem" \
    -CAkey "$dir/ca-key.pem" \
    -CAcreateserial \
    -out "$tmp/${name}.pem" \
    -days 3650 \
    -sha256 \
    -extfile "$extfile"
}

install_cert() {
  local name=$1
  install -m 0444 -o root -g kubernetes "$tmp/${name}.pem" "$dir/${name}.pem"
  install -m 0440 -o root -g kubernetes "$tmp/${name}-key.pem" "$dir/${name}-key.pem"
}

sign_cert kube-apiserver "/CN=kube-apiserver" "$tmp/apiserver.ext"
sign_cert kube-apiserver-kubelet-client "/CN=kube-apiserver-kubelet-client" "$client_ext"
sign_cert kube-apiserver-proxy-client "/CN=front-proxy-client" "$client_ext"
sign_cert kube-apiserver-etcd-client "/CN=kube-apiserver-etcd-client" "$client_ext"
sign_cert cluster-admin "/O=system:masters/CN=cluster-admin" "$client_ext"
sign_cert etcd "/CN=etcd" "$tmp/etcd.ext"
sign_cert kube-controller-manager "/CN=system:kube-controller-manager" "$tmp/controller.ext"
sign_cert kube-controller-manager-client "/O=system:kube-controller-manager/CN=system:kube-controller-manager" "$client_ext"
sign_cert kube-scheduler-client "/O=system:kube-scheduler/CN=system:kube-scheduler" "$client_ext"
sign_cert kube-addon-manager "/O=system:masters/CN=system:kube-addon-manager" "$client_ext"

for name in \
  kube-apiserver \
  kube-apiserver-kubelet-client \
  kube-apiserver-proxy-client \
  kube-apiserver-etcd-client \
  cluster-admin \
  etcd \
  kube-controller-manager \
  kube-controller-manager-client \
  kube-scheduler-client \
  kube-addon-manager
do
  install_cert "$name"
done

if [[ $worker == 1 ]]; then
  sign_cert kubelet "/CN=system:node:${host}" "$tmp/kubelet.ext"
  sign_cert kubelet-client "/O=system:nodes/CN=system:node:${host}" "$client_ext"
  sign_cert kube-proxy-client "/O=system:node-proxier/CN=system:kube-proxy" "$client_ext"
  for name in kubelet kubelet-client kube-proxy-client; do
    install_cert "$name"
  done
fi

printf '%s\n' "$KUBERNETES_PKI_STAMP" >"$tmp/pki-stamp"
install -m 0444 -o root -g kubernetes "$tmp/pki-stamp" "$dir/pki-stamp"
