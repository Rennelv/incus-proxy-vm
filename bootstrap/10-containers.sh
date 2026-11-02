#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/proxyvm/config/guest.env
source /opt/proxyvm/config/packages.sh
SRC='/opt/proxyvm/files/etc'

dnf install -y \
  --disablerepo=fedora-cisco-openh264 \
  "${PACKAGES_CONTAINERS[@]}"

install -D -m 0644 "$SRC/docker/daemon.json" /etc/docker/daemon.json
install -m 0644 "$SRC/systemd/resolved.conf.d/91-docker.conf" \
  /etc/systemd/resolved.conf.d/91-docker.conf

systemctl enable --now docker.service
dockerd --validate --config-file=/etc/docker/daemon.json
systemctl restart systemd-resolved.service

cat >/etc/systemd/system/proxyvm-docker-dns.service <<'UNIT'
[Unit]
Description=DNS service
Requires=docker.service
After=docker.service systemd-resolved.service

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart systemd-resolved.service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl reset-failed systemd-resolved.service proxyvm-docker-dns.service || true
systemctl enable --now proxyvm-docker-dns.service

ip -4 addr show docker0 | grep -Fq "${DOCKER_DNS_IP}/"
ss -lun | grep -Fq "${DOCKER_DNS_IP}:53"
grep -q "^${GUEST_USER}:" /etc/subuid
grep -q "^${GUEST_USER}:" /etc/subgid

docker --version
docker compose version
podman --version
