# openbao-tls.sh — listener certificate for this control member.
#
# openbao-tls.service runs this before openbao.service.
#
# Only cluster.bootstrap may mint /var/lib/openbao/tls/ca.crt, and only when
# that file is absent. A control member that is not bootstrap fails closed
# if ca.crt is absent and does not generate a CA. Copy ca.crt from the
# bootstrap member, or add openbao_ca_cert to this host's sops file so
# activation installs it. Copy ca.key as well when this node must sign its
# own listener certificate. Do not commit that ciphertext.
#
# An existing ca.crt is kept. tls.crt and tls.key are left in place when
# both already exist, so a rebuild does not rotate the listener certificate.
#
# A non-loopback address is added to the certificate. ca.crt is the trust
# anchor retry_join uses as leader_ca_cert_file for a non-loopback leader.
#
# Environment, set by the Nix wrapper:
#   OPENBAO_TLS_DIR        directory for the certificate files
#   OPENBAO_TLS_HOSTNAME   name placed on the certificate
#   OPENBAO_TLS_ADDRESS    member address; included as an IP SAN when it is not loopback
#   OPENBAO_TLS_BOOTSTRAP  1 only on cluster.bootstrap
#
# Wrapped by pkgs.writeShellApplication (errexit, nounset, pipefail; PATH
# includes openssl and coreutils).

dir=$OPENBAO_TLS_DIR
bootstrap=${OPENBAO_TLS_BOOTSTRAP:-0}
host=$OPENBAO_TLS_HOSTNAME
address=$OPENBAO_TLS_ADDRESS

install -d -m 0750 -o openbao -g openbao "$dir"

if [[ ! -s $dir/ca.crt ]]; then
  if [[ $bootstrap != 1 ]]; then
    echo "openbao-tls: ${dir}/ca.crt is absent. This control member is not cluster.bootstrap and will not mint an OpenBao CA." >&2
    echo "Copy ca.crt from the bootstrap member, or add openbao_ca_cert to this host's sops file so activation installs it. Do not commit ciphertext." >&2
    exit 1
  fi
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$tmp/ca.key" \
    -out "$tmp/ca.crt" \
    -subj "/CN=${host}-openbao-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  install -m 0400 -o openbao -g openbao "$tmp/ca.key" "$dir/ca.key"
  install -m 0444 -o openbao -g openbao "$tmp/ca.crt" "$dir/ca.crt"
  rm -rf "$tmp"
  trap - EXIT
fi

if [[ -s $dir/tls.crt && -s $dir/tls.key ]]; then
  exit 0
fi

if [[ ! -s $dir/ca.key ]]; then
  echo "openbao-tls: ca.crt is present but ca.key is not, and the listener certificate is absent. This node will not mint a new CA." >&2
  echo "Copy ca.key from the bootstrap member so this node can sign its listener certificate, or copy tls.crt and tls.key." >&2
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

install -m 0400 -o openbao -g openbao "$tmp/tls.key" "$dir/tls.key"
install -m 0444 -o openbao -g openbao "$tmp/tls.crt" "$dir/tls.crt"
