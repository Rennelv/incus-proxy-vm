#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/proxyvm/config/guest.env
[[ "$(id -u)" -eq 0 ]] || { echo 'Run as root: sudo bash /opt/proxyvm/tools/enable-enforcing.sh' >&2; exit 1; }
mode="$(getenforce)"
if [[ "$mode" == Enforcing ]]; then
  echo 'SELinux is already Enforcing.'
  exit 0
fi
[[ "$mode" == Permissive ]] || { echo "Expected Permissive after first reboot, got '$mode'. Do not skip relabel." >&2; exit 1; }
[[ ! -e /.autorelabel ]] || { echo 'Filesystem relabel is still scheduled, do not enable enforcing yet.' >&2; exit 1; }
rpm -q selinux-policy-targeted >/dev/null
all_services_active() {
  local unit
  for unit in incus-agent proxyvm-redsocks proxyvm-netfilter docker systemd-resolved sshd; do
    systemctl is-active --quiet "$unit" || { echo "Inactive service: $unit" >&2; return 1; }
  done
}
all_services_active
bash /opt/proxyvm/bootstrap/selinux-labels.sh
ls -Z /run/incus_agent/incus-agent | grep -Fq ':bin_t:'
setenforce 1
if ! {
  all_services_active &&
  curl -4 -fS --noproxy '*' --connect-timeout 8 --max-time 20 -o /dev/null "$TEST_URL" &&
  resolvectl query "$DNS_TEST_DOMAIN" >/dev/null
}; then
  echo 'SELinux Enforcing smoke test failed; returning to Permissive.' >&2
  setenforce 0
  exit 1
fi
cat >/etc/selinux/config <<'EOF'
SELINUX=enforcing
SELINUXTYPE=targeted
EOF
echo 'SELinux is Enforcing and persistent configuration is set.'
echo 'Reboot once more and verify Incus Agent + network + containers.'
