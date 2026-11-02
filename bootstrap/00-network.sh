#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/proxyvm/config/guest.env
source /opt/proxyvm/config/packages.sh

SOCKS="$PROXY_URL"
NIC="$GUEST_IFACE"
SRC='/opt/proxyvm/files/etc'

dnf install -y \
  --disablerepo=fedora-cisco-openh264 \
  --setopt="proxy=$SOCKS" \
  "${PACKAGES_NETWORK[@]}"
systemctl enable --now sshd

if [[ "$(getenforce)" == Disabled ]]; then
  if grep -Eq '(^|[[:space:]])selinux=0([[:space:]]|$)' /proc/cmdline; then
    echo 'SELinux was explicitly disabled by the kernel command line; review boot parameters first' >&2
    exit 1
  fi
  install -d /etc/selinux
  cat >/etc/selinux/config <<'SELINUX_CONFIG'
SELINUX=permissive
SELINUXTYPE=targeted
SELINUX_CONFIG
  touch /.autorelabel
  echo '[SELinux] Installed targeted policy; initial relabel is scheduled for the next reboot in Permissive mode.'
fi

install -m 0644 "$SRC/redsocks-proxyvm.conf" /etc/redsocks-proxyvm.conf
install -D -m 0644 "$SRC/nftables/proxyvm.nft" /etc/nftables/proxyvm.nft
install -m 0644 "$SRC/systemd/system/proxyvm-redsocks.service" /etc/systemd/system/proxyvm-redsocks.service
install -m 0644 "$SRC/systemd/system/proxyvm-netfilter.service" /etc/systemd/system/proxyvm-netfilter.service

install -d /etc/systemd/system/incus-agent.service.d
cat > /etc/systemd/system/incus-agent.service.d/90-proxyvm-selinux-label.conf <<'UNIT'
[Service]
ExecStartPre=/opt/proxyvm/bootstrap/selinux-labels.sh
UNIT
systemctl daemon-reload
bash /opt/proxyvm/bootstrap/selinux-labels.sh
if [[ "$(getenforce 2>/dev/null || true)" != Disabled ]]; then
  systemctl reset-failed incus-agent.service || true
  systemctl try-restart incus-agent.service || true
fi

networkfile="$(networkctl status "$NIC" --no-pager 2>/dev/null |
  sed -n 's/^[[:space:]]*Network File:[[:space:]]*//p' | head -1)"
if [[ "$networkfile" != /*.network ]]; then
  echo "Missing active .network file for $NIC; not risking network reconfiguration" >&2
  exit 1
fi
net_drop="/etc/systemd/network/$(basename "$networkfile").d"
install -d "$net_drop"
install -m 0644 "$SRC/systemd/network/90-proxyvm-dns.conf" "$net_drop/90-proxyvm-dns.conf"
install -m 0644 "$SRC/systemd/network/91-proxyvm-dhcp-id.conf" "$net_drop/91-proxyvm-dhcp-id.conf"

install -d /etc/systemd/resolved.conf.d
install -m 0644 "$SRC/systemd/resolved.conf.d/90-proxyvm-dot.conf" /etc/systemd/resolved.conf.d/90-proxyvm-dot.conf

/usr/bin/redsocks -t -c /etc/redsocks-proxyvm.conf
nft -c -f /etc/nftables/proxyvm.nft
systemctl daemon-reload
systemctl enable --now proxyvm-redsocks.service
systemctl enable --now proxyvm-netfilter.service
systemctl restart systemd-resolved.service
resolvectl flush-caches

curl -4 -fS --noproxy '*' --connect-timeout 10 --max-time 25 \
  -o /dev/null 'https://1.1.1.1/cdn-cgi/trace'
resolvectl query "$DNS_TEST_DOMAIN"
curl -4 -fS --noproxy '*' --connect-timeout 10 --max-time 25 \
  -o /dev/null "$TEST_URL"
echo 'Transparent TCP and DoT OK'
