# etcd-snapshot.sh — save an etcd snapshot under ETCD_BACKUP_DIR.
#
# The node sets kubernetes.etcd.backupDirectory, which becomes ETCD_BACKUP_DIR. Each run writes
# etcd-<utc>.db and keeps the newest 14 snapshots.
#
# Wrapped by pkgs.writeShellApplication (errexit, nounset, pipefail; PATH
# includes etcd and coreutils).

backup_dir=$ETCD_BACKUP_DIR
secrets=/var/lib/kubernetes/secrets
install -d -m 0700 -o etcd -g etcd "$backup_dir"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$backup_dir/etcd-$stamp.db"
ETCDCTL_API=3 etcdctl snapshot save "$out" \
  --endpoints=https://127.0.0.1:2379 \
  --cert="$secrets/kube-apiserver-etcd-client.pem" \
  --key="$secrets/kube-apiserver-etcd-client-key.pem" \
  --cacert="$secrets/ca.pem"
chown etcd:etcd "$out"
chmod 0400 "$out"

shopt -s nullglob
files=("$backup_dir"/etcd-*.db)
if ((${#files[@]} > 14)); then
  printf '%s\n' "${files[@]}" | sort | head -n -14 | while read -r old; do
    rm -f "$old"
  done
fi
