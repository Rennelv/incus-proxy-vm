#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${PROJECT_CONFIG:-$ROOT/config.json}"
[[ -r "$CONFIG" ]] || { echo "Create config.json from config.example.json first (or set PROJECT_CONFIG)." >&2; exit 2; }

usage() {
  echo 'Usage: ./create-vm.sh VM_NAME [HOST_WORKSPACE_DIR]'
  echo 'Override: PROJECT_CONFIG=/path/to/config.json SSH_PUBKEY=/path/to/id_ed25519.pub'
}
if [[ ${1:-} == '--help' || $# -eq 0 ]]; then usage; [[ $# -ne 0 ]] && exit 0 || exit 2; fi
[[ $# -le 2 ]] || { usage >&2; exit 2; }
VM="$1"
WORKSPACE="${2:-}"
KEY="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
[[ "$VM" =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] || { echo 'Invalid VM name' >&2; exit 2; }
[[ -r "$KEY" ]] || { echo "Missing SSH public key: $KEY" >&2; exit 2; }
if [[ -n "$WORKSPACE" ]]; then
  [[ -d "$WORKSPACE" ]] || { echo "Not a directory: $WORKSPACE" >&2; exit 2; }
  WORKSPACE="$(realpath "$WORKSPACE")"
fi
python3 "$ROOT/configure.py" --config "$CONFIG" validate >/dev/null
source <(python3 "$ROOT/configure.py" --config "$CONFIG" shell)
if (( EUID == 0 )); then INCUS=(incus); else INCUS=(/usr/bin/sudo incus); fi
"${INCUS[@]}" profile show "$PROFILE" >/dev/null
"${INCUS[@]}" network acl show "$ACL" >/dev/null
bridge_address="$("${INCUS[@]}" network get "$BRIDGE" ipv4.address)"
[[ "$bridge_address" == "$BRIDGE_IPV4" ]] || {
  echo "Bridge mismatch: $BRIDGE has $bridge_address but config requires $BRIDGE_IPV4" >&2; exit 3;
}
profile_devices="$("${INCUS[@]}" profile device show "$PROFILE")"
printf '%s\n' "$profile_devices" | grep -Fq "network: $BRIDGE" || {
  echo "Profile $PROFILE is not attached to bridge $BRIDGE" >&2; exit 3;
}
printf '%s\n' "$profile_devices" | grep -Fq "security.acls: $ACL" || {
  echo "Profile $PROFILE is missing ACL $ACL" >&2; exit 3;
}
if "${INCUS[@]}" info "$VM" >/dev/null 2>&1; then
  echo "Refusing to overwrite existing instance $VM" >&2; exit 3
fi
OUT="$ROOT/rendered/$VM.yaml"
python3 "$ROOT/configure.py" --config "$CONFIG" render "$VM" "$KEY" "$OUT"
printf 'Creating %s from %s (profile=%s; cpu=%s; memory=%s; disk=%s)\n' "$VM" "$IMAGE" "$PROFILE" "$CPUS" "$RAM" "$DISK"
"${INCUS[@]}" init "$IMAGE" "$VM" --vm --profile "$PROFILE"
"${INCUS[@]}" config set "$VM" "limits.cpu=$CPUS" "limits.memory=$RAM"
"${INCUS[@]}" config device override "$VM" root "size=$DISK"
if ! printf '%s\n' "$profile_devices" | grep -Fq 'source: cloud-init:config'; then
  "${INCUS[@]}" config device add "$VM" seed disk source=cloud-init:config
fi
if [[ -n "$WORKSPACE" ]]; then
  "${INCUS[@]}" config device add "$VM" workspace disk "source=$WORKSPACE" path=/workspace
fi
"${INCUS[@]}" config set "$VM" cloud-init.user-data - < "$OUT"
"${INCUS[@]}" start "$VM"
echo 'VM started. Guest may reboot automatically for SELinux labeling and final verification.'
printf 'Status: %s/status-vm.sh %s\n' "$ROOT" "$VM"
printf 'SSH: ssh %s@GUEST_IPV4\n' "$GUEST_USER"
