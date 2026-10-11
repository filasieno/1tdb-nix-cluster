# bootstrap-token-auth.sh — write the apiserver token file from a sops secret.
#
# kubernetes-bootstrap-token.service runs this on a control member only when
# kubernetes_bootstrap_token exists in that host's sops file. The token value
# is never printed and is not set in Nix. The CSV maps the token to the group
# system:bootstrappers. Durin does not run this unit until that key exists.
#
# Environment, set by the Nix wrapper:
#   KUBERNETES_BOOTSTRAP_TOKEN_FILE   sops secret, raw token
#   KUBERNETES_TOKEN_AUTH_FILE        CSV consumed by --token-auth-file
#
# Wrapped by pkgs.writeShellApplication (errexit, nounset, pipefail).

src=$KUBERNETES_BOOTSTRAP_TOKEN_FILE
out=$KUBERNETES_TOKEN_AUTH_FILE

if [[ ! -s $src ]]; then
  echo "kubernetes bootstrap token secret is missing. The token value is not set in Nix." >&2
  exit 1
fi

token=$(tr -d '[:space:]' <"$src")
if [[ -z $token || $token == *","* ]]; then
  echo "kubernetes bootstrap token secret is empty or contains a comma. The value is not logged." >&2
  exit 1
fi

install -d -m 0750 -o root -g kubernetes "$(dirname "$out")"
tmp=$(mktemp "$(dirname "$out")/bootstrap-token-auth.csv.XXXXXX")
chmod 0640 "$tmp"
printf '%s,%s,%s,%s\n' \
  "$token" \
  "system:bootstrap:kubelet" \
  "system:bootstrap:kubelet" \
  "system:bootstrappers" >"$tmp"
install -m 0440 -o root -g kubernetes "$tmp" "$out"
rm -f "$tmp"
