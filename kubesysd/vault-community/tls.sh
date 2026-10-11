# vault-tls.sh — listener certificate for the single Vault Community node.
#
# vault-tls.service runs this before vault.service.
#
# This host is the only Vault Community node, so it may mint
# /var/lib/vault/tls/ca.crt when that file is absent. Minting is not tied
# to cluster.bootstrap. An existing ca.crt is kept. tls.crt and tls.key are
# left in place when both already exist.
#
# Environment, set by the Nix wrapper:
#   VAULT_TLS_DIR        directory for the certificate files
#   VAULT_TLS_HOSTNAME   name placed on the certificate
#   VAULT_TLS_ADDRESS    member address; included as an IP SAN when it is not loopback
#
# Wrapped by pkgs.writeShellApplication (errexit, nounset, pipefail; PATH
# includes openssl and coreutils).

dir=$VAULT_TLS_DIR
host=$VAULT_TLS_HOSTNAME
address=$VAULT_TLS_ADDRESS

install -d -m 0750 -o vault -g vault "$dir"

if [[ ! -s $dir/ca.crt ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$tmp/ca.key" \
    -out "$tmp/ca.crt" \
    -subj "/CN=${host}-vault-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  install -m 0400 -o vault -g vault "$tmp/ca.key" "$dir/ca.key"
  install -m 0444 -o vault -g vault "$tmp/ca.crt" "$dir/ca.crt"
  rm -rf "$tmp"
  trap - EXIT
fi

if [[ -s $dir/tls.crt && -s $dir/tls.key ]]; then
  exit 0
fi

if [[ ! -s $dir/ca.key ]]; then
  echo "vault-tls: ca.crt is present but ca.key is not, and the listener certificate is absent. This node will not mint a new CA." >&2
  echo "Copy ca.key so this node can sign its listener certificate, or copy tls.crt and tls.key." >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sans="DNS:${host},DNS:localhost,IP:127.0.0.1"
if [[ $address != "127.0.0.1" ]]; then
  sans="${sans},IP:${address}"
fi

openssl genrsa -out "$tmp/tls.key" 2048
openssl req -new -key "$tmp/tls.key" -subj "/CN=${host}" -out "$tmp/tls.csr"
cat >"$tmp/tls.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${sans}
EOF
openssl x509 -req \
  -in "$tmp/tls.csr" \
  -CA "$dir/ca.crt" \
  -CAkey "$dir/ca.key" \
  -CAcreateserial \
  -out "$tmp/tls.crt" \
  -days 3650 \
  -sha256 \
  -extfile "$tmp/tls.ext"

install -m 0400 -o vault -g vault "$tmp/tls.key" "$dir/tls.key"
install -m 0444 -o vault -g vault "$tmp/tls.crt" "$dir/tls.crt"
