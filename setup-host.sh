#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${PROJECT_CONFIG:-$ROOT/config.json}"
[[ -r "$CONFIG" ]] || { echo "Create config.json from config.example.json first (or set PROJECT_CONFIG)." >&2; exit 2; }
[[ ${1:-} == --plan || ${1:-} == --apply ]] || {
  echo 'Usage: ./setup-host.sh --plan | --apply' >&2; exit 2
}
python3 "$ROOT/configure.py" --config "$CONFIG" validate >/dev/null
source <(python3 "$ROOT/configure.py" --config "$CONFIG" shell)
if (( EUID == 0 )); then INCUS=(incus); else INCUS=(/usr/bin/sudo incus); fi
if [[ "$1" == --plan ]]; then
  cat <<EOF
Incus host preparation plan (nothing will be changed):
  Create managed bridge: $BRIDGE IPv4=$BRIDGE_IPV4 IPv6=none
  Create ACL: $ACL
    Egress: allow TCP to $PROXY_HOST:$PROXY_PORT, default reject
    Ingress: allow SSH from bridge gateway ${BRIDGE_IPV4%/*}, default reject
  Create profile: $PROFILE
    root disk from pool $POOL, NIC on $BRIDGE with $ACL, cloud-init seed disk
  Local SOCKS5 proxy MUST ALREADY be listening at $PROXY_HOST:$PROXY_PORT.
This step does not install a proxy, create VMs, or alter existing objects.
EOF
  exit 0
fi
for required in "$BRIDGE:network" "$ACL:acl" "$PROFILE:profile"; do
  name="${required%:*}"; kind="${required#*:}"
  if [[ "$kind" == network ]]; then
    if "${INCUS[@]}" network show "$name" >/dev/null 2>&1; then
      echo "Refusing: network $name already exists" >&2; exit 3
    fi
  elif [[ "$kind" == acl ]]; then
    if "${INCUS[@]}" network acl show "$name" >/dev/null 2>&1; then
      echo "Refusing: ACL $name already exists" >&2; exit 3
    fi
  else
    if "${INCUS[@]}" profile show "$name" >/dev/null 2>&1; then
      echo "Refusing: profile $name already exists" >&2; exit 3
    fi
  fi
done
"${INCUS[@]}" storage show "$POOL" >/dev/null
"${INCUS[@]}" network create "$BRIDGE" "ipv4.address=$BRIDGE_IPV4" ipv4.nat=true ipv6.address=none
"${INCUS[@]}" network acl create "$ACL"
"${INCUS[@]}" network acl rule add "$ACL" egress \
  action=allow state=enabled protocol=tcp "destination=$PROXY_HOST" "destination_port=$PROXY_PORT"
"${INCUS[@]}" network acl rule add "$ACL" ingress \
  action=allow state=enabled protocol=tcp "source=${BRIDGE_IPV4%/*}" destination_port=22
"${INCUS[@]}" profile create "$PROFILE"
"${INCUS[@]}" profile device add "$PROFILE" root disk path=/ "pool=$POOL"
"${INCUS[@]}" profile device add "$PROFILE" eth0 nic name=eth0 "network=$BRIDGE" \
  "security.acls=$ACL" security.acls.default.ingress.action=reject security.acls.default.egress.action=reject
"${INCUS[@]}" profile device add "$PROFILE" seed disk source=cloud-init:config
echo "Created bridge $BRIDGE, ACL $ACL, profile $PROFILE. No existing objects were modified."
