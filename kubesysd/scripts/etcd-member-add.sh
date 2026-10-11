# etcd-member-add.sh — add this control member to the running etcd cluster.
#
# etcd-member-add.service runs on a control member that is not
# cluster.bootstrap, after kubernetes-pki and before etcd. etcd
# initialClusterState is derived: cluster.bootstrap is "new", and this
# member is "existing". The bootstrap member does not run this unit.
#
# etcdctl lock takes cluster/reconcile/etcd-member on the existing control
# endpoints. member add is skipped when this name or peer URL is already
# listed, whether that entry is a voting member or a learner.
#
# Add one control member per deploy. If initialCluster names a peer that is
# neither this node nor already in the member list, this script fails and
# etcd does not start. Two new control members in one edit do not join.
# The bootstrap member does not run this unit, so a single-member cluster
# is not blocked.
#
# Environment, set by the Nix wrapper:
#   ETCD_MEMBER_NAME
#   ETCD_MEMBER_ADDRESS
#   ETCD_PEER_PORT
#   ETCD_INITIAL_CLUSTER   comma-separated name=https://address:port entries
#   ETCDCTL_ENDPOINTS, ETCDCTL_CACERT, ETCDCTL_CERT, ETCDCTL_KEY
#
# Wrapped by pkgs.writeShellApplication (errexit, nounset, pipefail).

if [[ "${ETCD_MEMBER_LOCK_HELD:-}" != 1 ]]; then
  export ETCD_MEMBER_LOCK_HELD=1
  exec etcdctl lock cluster/reconcile/etcd-member --ttl=60 -- "$0"
fi

name=$ETCD_MEMBER_NAME
peer="https://${ETCD_MEMBER_ADDRESS}:${ETCD_PEER_PORT}"

if [[ -z ${ETCDCTL_ENDPOINTS} ]]; then
  echo "etcd-member-add: no existing control endpoint. This node does not form a new cluster." >&2
  exit 1
fi

listed() {
  local json=$1
  local want_name=$2
  local want_peer=$3
  jq -e --arg name "$want_name" --arg peer "$want_peer" '
    any((.members // [])[]; .name == $name or (((.peerURLs // []) | index($peer)) != null))
  ' <<<"$json" >/dev/null
}

members=$(etcdctl member list -w json)

if listed "$members" "$name" "$peer"; then
  exit 0
fi

missing=()
IFS=',' read -ra entries <<<"${ETCD_INITIAL_CLUSTER}"
for entry in "${entries[@]}"; do
  [[ -n $entry ]] || continue
  peer_name=${entry%%=*}
  peer_url=${entry#*=}
  if [[ $peer_name == "$name" ]]; then
    continue
  fi
  if ! listed "$members" "$peer_name" "$peer_url"; then
    missing+=("$entry")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "etcd-member-add: initialCluster lists a peer that is neither this node nor already in the member list: ${missing[*]}. Add one control member per deploy." >&2
  exit 1
fi

if ! etcdctl member add "$name" --peer-urls="$peer"; then
  members=$(etcdctl member list -w json)
  if listed "$members" "$name" "$peer"; then
    exit 0
  fi
  echo "etcd-member-add: failed to add ${name} at ${peer}" >&2
  exit 1
fi
