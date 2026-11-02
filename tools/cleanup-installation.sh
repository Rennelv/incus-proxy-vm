#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly STATEDIR=/var/lib/proxyvm
readonly MARKER="$STATEDIR/installation-cleaned"

if (( EUID != 0 )); then
  echo 'Run as root: sudo bash /opt/proxyvm/tools/cleanup-installation.sh' >&2
  exit 1
fi
if [[ -f "$MARKER" ]]; then
  echo 'Installation cleanup already completed.'
  exit 0
fi
[[ -f "$STATEDIR/ready" ]] || { echo 'Refusing cleanup: VM is not READY.' >&2; exit 1; }
[[ "$(getenforce)" == Enforcing ]] || { echo 'Refusing cleanup: SELinux is not Enforcing.' >&2; exit 1; }
[[ ! -e /.autorelabel ]] || { echo 'Refusing cleanup: SELinux relabel is pending.' >&2; exit 1; }
cloud_init_status="$(cloud-init status)"
[[ "$cloud_init_status" == *'status: done'* ]] || {
  printf 'Refusing cleanup: cloud-init is not done (%s).\n' "$cloud_init_status" >&2
  exit 1
}
for svc in incus-agent.service proxyvm-netfilter.service proxyvm-redsocks.service docker.service systemd-resolved.service sshd.service proxyvm-docker-dns.service; do
  systemctl is-active --quiet "$svc" || { echo "Refusing cleanup: $svc inactive." >&2; exit 1; }
done
if [[ ! -f /etc/systemd/system/incus-agent.service.d/90-proxyvm-selinux-label.conf       && ! -f /etc/systemd/system/incus-agent.service.d/10-context.conf ]]; then
  echo 'Refusing cleanup: no known Incus Agent label hook found.' >&2
  exit 1
fi
[[ -x /usr/sbin/restorecon ]] || { echo 'restorecon unavailable.' >&2; exit 1; }
if ! semanage fcontext -l -C | grep -F '/run/incus_agent/incus-agent' | grep -Fq 'bin_t'; then
  echo 'Refusing cleanup: persistent bin_t fcontext for Incus Agent not registered.' >&2
  exit 1
fi
[[ -f /run/incus_agent/incus-agent ]] || { echo 'Incus Agent binary missing.' >&2; exit 1; }
[[ "$(ls -Z /run/incus_agent/incus-agent)" == *':bin_t:'* ]] || {
  echo 'Incus Agent label is not bin_t.' >&2
  exit 1
}

instance_dir="$(readlink -f /var/lib/cloud/instance || true)"
[[ "$instance_dir" == /var/lib/cloud/instances/* && -d "$instance_dir" ]] || {
  echo "Refusing cleanup: unexpected cloud-init instance path '$instance_dir'" >&2
  exit 1
}

/usr/sbin/nft -c -f /etc/nftables/proxyvm.nft
/usr/bin/redsocks -t -c /etc/redsocks-proxyvm.conf

echo '[CLEANUP] Replacing the Incus Agent label hook with a built-in tool.'
install -d -m 0755 /etc/systemd/system/incus-agent.service.d
cat > /etc/systemd/system/incus-agent.service.d/10-context.conf <<'UNIT'
[Service]
ExecStartPre=/usr/sbin/restorecon /run/incus_agent/incus-agent
UNIT
chmod 0644 /etc/systemd/system/incus-agent.service.d/10-context.conf
/usr/sbin/restorecon /run/incus_agent/incus-agent
[[ "$(ls -Z /run/incus_agent/incus-agent)" == *':bin_t:'* ]] || {
  echo 'Refusing to remove old hook: new restorecon did not preserve bin_t.' >&2
  exit 1
}
rm -f /etc/systemd/system/incus-agent.service.d/90-proxyvm-selinux-label.conf

echo '[CLEANUP] Neutralizing service descriptions.'
for unit in proxyvm-netfilter.service proxyvm-redsocks.service proxyvm-docker-dns.service; do
  path="/etc/systemd/system/$unit"
  [[ -f "$path" ]] || { echo "Required unit missing: $path" >&2; exit 1; }
  sed -i -E 's/^Description=.*/Description=Network service/' "$path"
done

echo '[CLEANUP] Disabling completed first-boot finalizer.'
if [[ -f /etc/systemd/system/proxyvm-finalize.service ]]; then
  systemctl disable proxyvm-finalize.service
  rm -f /etc/systemd/system/proxyvm-finalize.service
fi
systemctl daemon-reload
systemctl is-active --quiet incus-agent.service
systemctl is-active --quiet proxyvm-netfilter.service
systemctl is-active --quiet proxyvm-redsocks.service

echo '[CLEANUP] Removing explanatory policy comments.'
tmp="$(mktemp /etc/nftables/.proxyvm-clean.XXXXXXXX)"
trap 'rm -f -- "$tmp"' EXIT
awk 'NR == 1 && /^#!/ { print; next } !/^[[:space:]]*#/' /etc/nftables/proxyvm.nft > "$tmp"
chmod 0644 "$tmp"
/usr/sbin/nft -c -f "$tmp"
cat "$tmp" > /etc/nftables/proxyvm.nft
rm -f -- "$tmp"
trap - EXIT

echo '[CLEANUP] Removing local copies of cloud-init input.'
for name in user-data.txt user-data.txt.i cloud-config.txt obj.pkl; do
  rm -f -- "$instance_dir/$name"
done
rm -rf -- "$instance_dir/scripts" "$instance_dir/handlers"
for seed_dir in /var/lib/cloud/seed/nocloud /var/lib/cloud/seed/nocloud-net; do
  if [[ -d "$seed_dir" ]]; then
    rm -f -- "$seed_dir/user-data"
  fi
done
rm -f -- /run/cloud-init/combined-cloud-config.json /run/cloud-init/instance-data-sensitive.json

rm -f -- /var/log/proxyvm-bootstrap.log /var/log/proxyvm-finalize.log \
  /var/log/cloud-init.log /var/log/cloud-init-output.log

find "$STATEDIR" -maxdepth 1 -type f ! -name ready ! -name finalize.state \
  ! -name installation-cleaned -delete
printf 'READY\n' > "$STATEDIR/finalize.state"
echo '[CLEANUP] Removing bootstrap and installation tools.'
rm -rf -- /opt/proxyvm
touch "$MARKER"

echo '[CLEANUP] Guest cleanup complete. NOW detach the seed and unset'
echo '          cloud-init.user-data from the host, before the next reboot.'
echo '          Keep the same VM powered on until that host step succeeds.'
