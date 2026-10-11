#!/usr/bin/env bash
# shellcheck shell=bash
install -d -m 0700 -o etcd -g etcd "$ETCD_BACKUP_DIR"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$ETCD_BACKUP_DIR/etcd-$stamp.db"
ETCDCTL_API=3 etcdctl snapshot save "$out" \
  --endpoints="$ETCD_ENDPOINT" \
  --cert="$ETCD_CERT" \
  --key="$ETCD_KEY" \
  --cacert="$ETCD_CACERT"
chown etcd:etcd "$out"
chmod 0400 "$out"

shopt -s nullglob
files=("$ETCD_BACKUP_DIR"/etcd-*.db)
if ((${#files[@]} > 14)); then
  printf '%s\n' "${files[@]}" | sort | head -n -14 | while read -r old; do
    rm -f "$old"
  done
fi
