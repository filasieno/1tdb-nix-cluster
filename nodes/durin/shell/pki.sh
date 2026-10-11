#!/usr/bin/env bash
# shellcheck shell=bash
dir=$KUBERNETES_SECRETS_DIR
host=$KUBERNETES_HOSTNAME
cluster=$KUBERNETES_CLUSTER_NAME
service_ip=$KUBERNETES_SERVICE_IP
lan_ip=$KUBERNETES_LAN_ADDRESS

install -d -m 0750 -o root -g kubernetes "$dir"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

have() {
  [[ -s $dir/$1.pem && -s $dir/$1-key.pem ]]
}

publish() {
  local name=$1
  install -m 0444 -o root -g kubernetes "$tmp/$name.crt" "$dir/$name.pem"
  install -m 0440 -o root -g kubernetes "$tmp/$name.key" "$dir/$name-key.pem"
}

if ! have ca; then
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$tmp/ca.key" \
    -out "$tmp/ca.crt" \
    -subj "/CN=${cluster}" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  publish ca
fi

# ca-key.pem stays 0440 root:kubernetes. kube-controller-manager runs as
# kubernetes and signs kubelet CSRs with it. etcd is not in that group.

sign() {
  local name=$1 subject=$2 ext=$3
  if have "$name"; then
    return 0
  fi
  openssl genrsa -out "$tmp/$name.key" 2048
  openssl req -new -key "$tmp/$name.key" -subj "$subject" -out "$tmp/$name.csr"
  printf '%s\n' "$ext" >"$tmp/$name.ext"
  openssl x509 -req \
    -in "$tmp/$name.csr" \
    -CA "$dir/ca.pem" \
    -CAkey "$dir/ca-key.pem" \
    -CAcreateserial \
    -out "$tmp/$name.crt" \
    -days 3650 \
    -sha256 \
    -extfile "$tmp/$name.ext"
  publish "$name"
}

client='basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth'

server() {
  printf '%s\n' \
    "basicConstraints=CA:FALSE" \
    "keyUsage=critical,digitalSignature,keyEncipherment" \
    "extendedKeyUsage=serverAuth" \
    "subjectAltName=$1"
}

both() {
  printf '%s\n' \
    "basicConstraints=CA:FALSE" \
    "keyUsage=critical,digitalSignature,keyEncipherment" \
    "extendedKeyUsage=serverAuth,clientAuth" \
    "subjectAltName=$1"
}

api_sans="DNS:${host},DNS:${cluster},DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,DNS:localhost,IP:127.0.0.1,IP:127.0.0.2,IP:${service_ip},IP:${lan_ip}"
extra_domains=${KUBERNETES_API_DOMAINS:-}
if [[ -n $extra_domains ]]; then
  IFS=',' read -ra extra_names <<<"$extra_domains"
  for name in "${extra_names[@]}"; do
    [[ -n $name ]] || continue
    api_sans="${api_sans},DNS:${name}"
  done
fi
host_sans="DNS:${host},DNS:localhost,IP:127.0.0.1"
kubelet_sans="DNS:${host},DNS:localhost,IP:127.0.0.1,IP:${lan_ip}"

# A certificate already on disk keeps its old names. Replace the API
# server certificate when the SAN list changes. The CA stays.
sans_stamp=$dir/kube-apiserver.sans
recorded=""
if [[ -s $sans_stamp ]]; then
  recorded=$(<"$sans_stamp")
fi
if [[ -s $dir/kube-apiserver.pem && $recorded != "$api_sans" ]]; then
  rm -f "$dir/kube-apiserver.pem" "$dir/kube-apiserver-key.pem"
fi

sign kube-apiserver "/CN=kube-apiserver" "$(server "$api_sans")"
if [[ -s $dir/kube-apiserver.pem ]]; then
  printf '%s\n' "$api_sans" >"$sans_stamp"
  chown root:kubernetes "$sans_stamp"
  chmod 0444 "$sans_stamp"
fi
sign kube-apiserver-kubelet-client "/CN=kube-apiserver-kubelet-client" "$client"
sign kube-apiserver-proxy-client "/CN=front-proxy-client" "$client"
sign kube-apiserver-etcd-client "/CN=kube-apiserver-etcd-client" "$client"
sign etcd "/CN=${host}" "$(both "$host_sans")"
# etcd is not in group kubernetes. Its own key stays readable only by etcd.
if [[ -s $dir/etcd-key.pem ]]; then
  chown etcd:etcd "$dir/etcd.pem" "$dir/etcd-key.pem"
  chmod 0444 "$dir/etcd.pem"
  chmod 0400 "$dir/etcd-key.pem"
fi
sign kube-controller-manager "/CN=system:kube-controller-manager" "$(server "$host_sans")"
sign kube-controller-manager-client "/CN=system:kube-controller-manager" "$client"
sign kube-scheduler-client "/CN=system:kube-scheduler" "$client"
sign kube-addon-manager "/CN=system:kube-addon-manager" "$client"

kubelet_stamp=$dir/kubelet.sans
kubelet_recorded=""
if [[ -s $kubelet_stamp ]]; then
  kubelet_recorded=$(<"$kubelet_stamp")
fi
if [[ -s $dir/kubelet.pem && $kubelet_recorded != "$kubelet_sans" ]]; then
  rm -f "$dir/kubelet.pem" "$dir/kubelet-key.pem"
fi
sign kubelet "/CN=system:node:${host}" "$(server "$kubelet_sans")"
if [[ -s $dir/kubelet.pem ]]; then
  printf '%s\n' "$kubelet_sans" >"$kubelet_stamp"
  chown root:kubernetes "$kubelet_stamp"
  chmod 0444 "$kubelet_stamp"
fi
sign kubelet-client "/O=system:nodes/CN=system:node:${host}" "$client"
sign cluster-admin "/O=system:masters/CN=cluster-admin" "$client"

if ! have service-account; then
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$tmp/service-account.key" \
    -out "$tmp/service-account.crt" \
    -subj "/CN=system:service-account-signer"
  publish service-account
fi
