#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]; then
  echo 'Usage: ./detach-seed.sh VM_NAME' >&2
  exit 2
fi
VM="$1"
if [[ -n ${INCUS_CLI:-} ]]; then
  INCUS=("$INCUS_CLI")
elif (( EUID == 0 )); then
  INCUS=(incus)
else
  INCUS=(/usr/bin/sudo incus)
fi

echo "[1/3] Cleaning guest $VM (installation files, logs, system journal)."
"${INCUS[@]}" exec "$VM" -- /bin/bash -euc '
  marker=/var/lib/proxyvm/installation-cleaned
  cleaner=/opt/proxyvm/tools/cleanup-installation.sh
  if [[ -f "$marker" ]]; then
    echo "Guest installation already cleaned."
  elif [[ -f "$cleaner" ]]; then
    /bin/bash "$cleaner"
  else
    echo "ERROR: no cleanup script and no completed-cleanup marker." >&2
    exit 1
  fi
  [[ -f "$marker" ]] || { echo "ERROR: cleanup marker missing." >&2; exit 1; }
  [[ ! -e /opt/proxyvm ]] || { echo "ERROR: bootstrap files still present." >&2; exit 1; }
  [[ ! -e /var/lib/cloud/instance/user-data.txt ]] || {
    echo "ERROR: cloud-init user-data still present in guest." >&2
    exit 1
  }
  for f in /var/log/proxyvm-bootstrap.log /var/log/proxyvm-finalize.log \
           /var/log/cloud-init.log /var/log/cloud-init-output.log; do
    [[ ! -e "$f" ]] || { echo "ERROR: installation log still present: $f" >&2; exit 1; }
  done
  if [[ -d /var/log ]]; then
    find /var/log -maxdepth 1 -type f \( -name "dnf*.log*" -o -name "hawkey.log*" \) -delete
  fi
  journalctl --rotate --vacuum-time=1s >/dev/null
  echo "Guest cleanup verified; old system journal rotated and vacuumed."
'

echo "[2/3] Disabling cloud-init seed for $VM."
# This is the INSTANCE's local device config (not expanded from profiles).
local_devices="$("${INCUS[@]}" config device show "$VM")"
seed_properties="$(printf '%s\n' "$local_devices" | awk '
  /^seed:$/ { found=1; next }
  found && /^[^[:space:]]/ { exit }
  found && /^[[:space:]]+(type|source):[[:space:]]/ { print $1, $2 }
')"
local_type="$(printf '%s\n' "$seed_properties" | awk '$1 == "type:" { print $2; exit }')"
local_source="$(printf '%s\n' "$seed_properties" | awk '$1 == "source:" { print $2; exit }')"

case "$local_type" in
  '')
    # Inherited disk: override on this VM with 'none', keeping the shared profile intact.
    echo "Disabling inherited seed for $VM with a per-instance 'none' device."
    "${INCUS[@]}" config device add "$VM" seed none
    ;;
  none)
    echo "Seed already masked locally on $VM."
    ;;
  disk)
    # In environments without a profile seed, create-vm.sh adds a local disk.
    if [[ "$local_source" != 'cloud-init:config' ]]; then
      echo "Refusing to remove non-cloud-init seed disk (source=$local_source)." >&2
      exit 1
    fi
    echo "Removing locally configured cloud-init seed disk from $VM."
    "${INCUS[@]}" config device remove "$VM" seed
    ;;
  *)
    echo "Refusing unexpected local seed device type: $local_type" >&2
    exit 1
    ;;
esac

# Verify the EFFECTIVE device, not only the locally defined override. If a
# profile disk reappeared after removing a local one, do not continue.
expanded_config="$("${INCUS[@]}" config show "$VM" --expanded)"
effective_type="$(printf '%s\n' "$expanded_config" | awk '
  /^devices:$/ { in_devices=1; next }
  in_devices && /^[^[:space:]]/ { exit }
  in_devices && /^  seed:$/ { in_seed=1; next }
  in_seed && /^  [^[:space:]]/ { exit }
  in_seed && /^    type:[[:space:]]/ { print $2; exit }
')"
if [[ "$local_type" == disk && "$effective_type" == disk ]]; then
  effective_source="$(printf '%s\n' "$expanded_config" | awk '
    /^devices:$/ { in_devices=1; next }
    in_devices && /^[^[:space:]]/ { exit }
    in_devices && /^  seed:$/ { in_seed=1; next }
    in_seed && /^  [^[:space:]]/ { exit }
    in_seed && /^    source:[[:space:]]/ { print $2; exit }
  ')"
  if [[ "$effective_source" == cloud-init:config ]]; then
    echo "Masking inherited seed after removing local device."
    "${INCUS[@]}" config device add "$VM" seed none
    expanded_config="$("${INCUS[@]}" config show "$VM" --expanded)"
    effective_type="$(printf '%s\n' "$expanded_config" | awk '
      /^devices:$/ { in_devices=1; next }
      in_devices && /^[^[:space:]]/ { exit }
      in_devices && /^  seed:$/ { in_seed=1; next }
      in_seed && /^  [^[:space:]]/ { exit }
      in_seed && /^    type:[[:space:]]/ { print $2; exit }
    ')"
  fi
fi
if [[ -n "$effective_type" && "$effective_type" != 'none' ]]; then
  echo "ERROR: seed still active in effective instance config (type=$effective_type)." >&2
  echo "Do NOT remove it from the shared profile; inspect this instance's devices." >&2
  exit 1
fi

echo "[3/3] Clearing Incus cloud-init user-data for $VM."
"${INCUS[@]}" config unset "$VM" cloud-init.user-data
printf 'Guest cleaned, seed disabled in instance config and cloud-init.user-data unset for %s.\n' "$VM"
echo 'For VM disks that cannot hot-unplug, restart this VM and verify incus_seed is absent.'
