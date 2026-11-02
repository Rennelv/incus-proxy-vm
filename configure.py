#!/usr/bin/env python3
"""Validate public settings and render cloud-init artifacts (Python stdlib only)."""
from __future__ import annotations

import argparse
import base64
import ipaddress
import json
import pathlib
import re
import shlex
import sys
import textwrap
from urllib.parse import urlparse

ROOT = pathlib.Path(__file__).resolve().parent
NAME = re.compile(r'^[a-z][a-z0-9-]{0,61}[a-z0-9]$')
USER = re.compile(r'^[a-z_][a-z0-9_-]{0,30}$')
PACKAGE = re.compile(r'^[a-zA-Z0-9_+.@:-]+$')
INTERFACE = re.compile(r'^[a-zA-Z0-9_.:-]{1,15}$')
SHELL_MAP = {
    'IMAGE': ('incus', 'image'), 'PROFILE': ('incus', 'profile'),
    'BRIDGE': ('incus', 'bridge'), 'BRIDGE_IPV4': ('incus', 'bridge_ipv4'),
    'ACL': ('incus', 'acl'), 'POOL': ('incus', 'storage_pool'),
    'CPUS': ('incus', 'cpu'), 'RAM': ('incus', 'memory'),
    'DISK': ('incus', 'disk'), 'GUEST_USER': ('incus', 'guest_user'),
    'GUEST_IFACE': ('incus', 'guest_interface'),
    'PROXY_HOST': ('proxy', 'host'), 'PROXY_PORT': ('proxy', 'port'),
}


def load_config(path: str | pathlib.Path) -> dict:
    config = json.loads(pathlib.Path(path).read_text(encoding='utf-8'))
    if not isinstance(config, dict):
        raise ValueError('config must be a JSON object')
    for section in ('incus', 'proxy', 'dns', 'packages', 'tools'):
        if not isinstance(config.get(section), dict):
            raise ValueError(f'missing {section} object')
    incus, proxy, dns, packages, tools = (config[k] for k in ('incus', 'proxy', 'dns', 'packages', 'tools'))
    for field in ('profile', 'bridge', 'acl'):
        if not NAME.fullmatch(incus[field]):
            raise ValueError(f'incus.{field}: invalid name')
    if not NAME.fullmatch(incus['guest_user']) and not USER.fullmatch(incus['guest_user']):
        raise ValueError('incus.guest_user: invalid Linux username')
    if incus['guest_user'] in ('root', 'redsocks', 'nobody', 'docker'):
        raise ValueError('incus.guest_user: reserved system user')
    if not INTERFACE.fullmatch(incus['guest_interface']):
        raise ValueError('incus.guest_interface: invalid name')
    if not re.fullmatch(r'[A-Za-z0-9_./:@+-]+', incus['image']):
        raise ValueError('incus.image: invalid reference')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', incus['storage_pool']):
        raise ValueError('incus.storage_pool: invalid name')
    if not re.fullmatch(r'[1-9][0-9]*', str(incus['cpu'])):
        raise ValueError('incus.cpu must be a positive integer')
    for field in ('memory', 'disk'):
        if not re.fullmatch(r'[1-9][0-9]*(MiB|GiB|TiB)', incus[field]):
            raise ValueError(f'incus.{field}: use e.g. 4GiB')
    network = ipaddress.ip_interface(incus['bridge_ipv4'])
    if network.version != 4 or network.network.prefixlen > 30 or network.ip == network.network.network_address or network.ip == network.network.broadcast_address:
        raise ValueError('bridge_ipv4 must be a usable IPv4 bridge address/prefix')
    proxy_host = ipaddress.ip_address(proxy['host'])
    if proxy_host.version != 4 or proxy_host.is_loopback or proxy_host.is_unspecified or proxy_host.is_multicast or proxy_host.is_link_local:
        raise ValueError('proxy.host must be a reachable unicast IPv4 address (not loopback)')
    if proxy['protocol'] != 'socks5':
        raise ValueError('only SOCKS5 is supported by the preserved redsocks pipeline')
    for field in ('port', 'redirect_port'):
        if not isinstance(proxy[field], int) or not (1 <= proxy[field] <= 65535):
            raise ValueError(f'proxy.{field}: invalid port')
    if proxy['port'] == proxy['redirect_port'] and proxy_host == network.ip:
        raise ValueError('proxy port and local redirect port must differ')
    bridge_ip = ipaddress.ip_address(dns['docker_bridge_ip'])
    if bridge_ip.version != 4 or not bridge_ip.is_private:
        raise ValueError('docker_bridge_ip must be private IPv4')
    if bridge_ip == proxy_host or bridge_ip in network.network:
        raise ValueError('Docker DNS bridge conflicts with proxy or Incus bridge')
    if not re.fullmatch(r'[a-zA-Z0-9.-]+', dns['test_domain']):
        raise ValueError('invalid dns.test_domain')
    if not isinstance(dns['servers'], list) or not dns['servers']:
        raise ValueError('dns.servers must be nonempty')
    for server in dns['servers']:
        if not isinstance(server, str) or not re.fullmatch(r'[0-9a-fA-F:.]+#[a-zA-Z0-9.-]+', server):
            raise ValueError(f'invalid DoT server: {server!r}')
        ipaddress.ip_address(server.split('#')[0])
    for section in ('network', 'containers', 'development', 'browser'):
        value = packages.get(section)
        if not isinstance(value, list) or not value or any(not isinstance(p, str) or not PACKAGE.fullmatch(p) for p in value):
            raise ValueError(f'packages.{section}: expected a nonempty list of RPM names')
    for tool in ('pnpm', 'bun', 'uv', 'claude', 'codex', 'opencode', 'antigravity', 'playwright', 'x11_forwarding'):
        if type(tools.get(tool)) is not bool:
            raise ValueError(f'tools.{tool} must be boolean')
    for field in ('bun_installer', 'uv_installer', 'claude_installer', 'opencode_installer', 'antigravity_installer'):
        value = tools[field]
        parsed = urlparse(value)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or any(ch in value for ch in '\n\r\t'):
            raise ValueError(f'tools.{field}: expected HTTPS URL without credentials')
    for field in ('codex_npm_package', 'pnpm_npm_package', 'playwright_npm_package'):
        name = tools[field]
        if not isinstance(name, str) or not name or name.startswith('-') or not re.fullmatch(r'[a-zA-Z0-9_.@/+\-]+', name):
            raise ValueError(f'tools.{field}: invalid npm package specification')
    # Reject accidental inclusion of credentials or undeclared settings.
    def guard(node, path=''):
        if isinstance(node, dict):
            for key, val in node.items():
                if re.search(r'(password|secret|token|private.?key|credential|api.?key)', key, re.I):
                    raise ValueError(f'credentials are not allowed in config: {path}{key}')
                guard(val, path + key + '.')
    guard(config)
    return config


def guest_env(config: dict) -> bytes:
    i, p, d, t = (config[k] for k in ('incus', 'proxy', 'dns', 'tools'))
    vals = {
        'GUEST_USER': i['guest_user'], 'GUEST_HOME': '/home/' + i['guest_user'],
        'GUEST_IFACE': i['guest_interface'], 'PROXY_HOST': p['host'],
        'PROXY_PORT': str(p['port']), 'PROXY_REDIRECT_PORT': str(p['redirect_port']),
        'PROXY_URL': f"socks5h://{p['host']}:{p['port']}",
        'DOCKER_DNS_IP': d['docker_bridge_ip'], 'DNS_TEST_DOMAIN': d['test_domain'],
        'TEST_URL': f"https://{d['test_domain']}",
    }
    for key, val in t.items():
        env_key = key.upper()
        vals['TOOL_' + env_key] = '1' if val is True else '0' if val is False else str(val)
    return ''.join(f'{key}={shlex.quote(val)}\n' for key, val in vals.items()).encode()


def package_env(config: dict) -> bytes:
    return ''.join(f"PACKAGES_{key.upper()}=({' '.join(shlex.quote(v) for v in values)})\n" for key, values in config['packages'].items()).encode()


def runtime_files(config: dict) -> dict[str, bytes]:
    p, i, d = config['proxy'], config['incus'], config['dns']
    source = ROOT / 'files'
    files = {'/opt/proxyvm/' + path.relative_to(ROOT).as_posix(): path.read_bytes() for path in source.rglob('*') if path.is_file()}
    replace = {
        '{{BRIDGE_SUBNET}}': str(ipaddress.ip_interface(i['bridge_ipv4']).network),
        '{{PROXY_HOST}}': p['host'],
        '{{PROXY_PORT}}': str(p['port']),
        '{{REDIRECT_PORT}}': str(p['redirect_port']),
        '{{GUEST_INTERFACE}}': i['guest_interface'],
        '{{DOCKER_DNS_IP}}': d['docker_bridge_ip'],
        '{{DOT_SERVERS}}': ' '.join(d['servers']),
    }
    for dest, contents in files.items():
        data = contents.decode('utf-8')
        for token, value in replace.items():
            data = data.replace(token, value)
        if '{{' in data or '}}' in data:
            raise ValueError(f'unrendered template token: {dest}')
        files[dest] = data.encode('utf-8')
    # Docker bridge IP may differ from 172.17.0.1. Default Docker bip must match.
    docker_conf = json.loads(files['/opt/proxyvm/files/etc/docker/daemon.json'])
    docker_conf['bip'] = d['docker_bridge_ip'] + '/16'
    files['/opt/proxyvm/files/etc/docker/daemon.json'] = (json.dumps(docker_conf, indent=2) + '\n').encode()
    # Ensure the proxy host bypasses transparent redirection even when off-bridge.
    nft_path = '/opt/proxyvm/files/etc/nftables/proxyvm.nft'
    nft = files[nft_path].decode()
    if ipaddress.ip_address(p['host']) not in ipaddress.ip_network(i['bridge_ipv4'], strict=False):
        nft = nft.replace('            127.0.0.0/8,', f"            {p['host']}/32,\n            127.0.0.0/8,")
    files[nft_path] = nft.encode()
    return files


def all_guest_files(config: dict) -> dict[str, bytes]:
    files = {'/opt/proxyvm/' + path.relative_to(ROOT).as_posix(): path.read_bytes()
             for folder in ('bootstrap', 'tools') for path in (ROOT / folder).glob('*.sh')}
    files.update(runtime_files(config))
    files['/opt/proxyvm/config/guest.env'] = guest_env(config)
    files['/opt/proxyvm/config/packages.sh'] = package_env(config)
    return dict(sorted(files.items()))


def render_cloud_init(config: dict, name: str, pubkey_path: str, destination: str) -> None:
    if not NAME.fullmatch(name):
        raise ValueError('invalid VM name; use lowercase letters, digits, hyphens')
    key = pathlib.Path(pubkey_path).read_text(encoding='utf-8').strip()
    if not re.fullmatch(r'(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|sk-ssh-ed25519@openssh.com)\s+[A-Za-z0-9+/=]+(?:\s+[^\n]*)?', key):
        raise ValueError('invalid or unsupported SSH public key')
    user = config['incus']['guest_user']
    lines = [
        '#cloud-config', f'hostname: {json.dumps(name)}', 'ssh_pwauth: false',
        'disable_root: true', 'package_update: false', 'package_upgrade: false',
        'users:', f'  - name: {json.dumps(user)}', '    shell: /bin/bash',
        '    groups: [wheel]', '    sudo: ["ALL=(ALL) NOPASSWD:ALL"]',
        '    lock_passwd: true', '    ssh_authorized_keys:',
        f'      - {json.dumps(key)}', 'growpart:', '  mode: auto',
        '  devices: ["/"]', 'resize_rootfs: true', 'write_files:',
    ]
    files = all_guest_files(config)
    for path, content in files.items():
        encoded = base64.b64encode(content).decode('ascii')
        lines.extend((f'  - path: {json.dumps(path)}', '    owner: root:root',
                      f"    permissions: '{'0755' if path.endswith('.sh') else '0644'}'",
                      '    encoding: b64', '    content: |'))
        lines.extend('      ' + line for line in textwrap.wrap(encoded, width=76))
    lines.extend(('runcmd:', '  - [bash, /opt/proxyvm/bootstrap/entrypoint.sh]', ''))
    pathlib.Path(destination).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(destination).write_text('\n'.join(lines), encoding='utf-8')
    print(f'cloud-init generated: {destination} ({len(files)} files)')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default=str(ROOT / 'config.json' if (ROOT / 'config.json').exists() else ROOT / 'config.example.json'))
    subs = parser.add_subparsers(dest='command', required=True)
    subs.add_parser('validate')
    subs.add_parser('shell')
    rendered = subs.add_parser('render')
    rendered.add_argument('name')
    rendered.add_argument('pubkey')
    rendered.add_argument('output')
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        if args.command == 'validate':
            print('Configuration OK')
        elif args.command == 'shell':
            for key, path in SHELL_MAP.items():
                val = config[path[0]][path[1]]
                print(f'{key}={shlex.quote(str(val))}')
        else:
            render_cloud_init(config, args.name, args.pubkey, args.output)
    except (ValueError, TypeError, KeyError, OSError) as ex:
        parser.exit(2, f'ERROR: {ex}\n')


if __name__ == '__main__':
    main()
