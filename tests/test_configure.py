import base64
import copy
import ipaddress
import json
import pathlib
import tempfile
import unittest

import configure


class CloudInitTests(unittest.TestCase):
    def setUp(self):
        self.config = configure.load_config(configure.ROOT / 'config.example.json')

    def test_default_config_and_guest_files(self):
        files = configure.all_guest_files(self.config)
        self.assertGreaterEqual(len(files), 25)
        self.assertIn('/opt/proxyvm/bootstrap/finalize.sh', files)
        self.assertIn('/opt/proxyvm/tools/cleanup-installation.sh', files)
        nft = files['/opt/proxyvm/files/etc/nftables/proxyvm.nft'].decode()
        self.assertIn('10.77.88.0/24', nft)
        self.assertIn('10.77.88.1 tcp dport 10808', nft)
        self.assertIn('iifname "enp5s0"', nft)
        self.assertNotIn('{{', nft)
        self.assertIn('DNS=9.9.9.9#dns.quad9.net', files['/opt/proxyvm/files/etc/systemd/resolved.conf.d/90-proxyvm-dot.conf'].decode())
        docker = json.loads(files['/opt/proxyvm/files/etc/docker/daemon.json'])
        self.assertEqual(docker['dns'], ['172.17.0.1'])
        self.assertEqual(docker['bip'], '172.17.0.1/16')

    def test_alt_network_config(self):
        c = copy.deepcopy(self.config)
        c['incus']['bridge_ipv4'] = '10.42.13.1/24'
        c['incus']['guest_interface'] = 'eth0'
        c['proxy']['host'] = '10.42.99.30'
        c['proxy']['port'] = 9050
        c['proxy']['redirect_port'] = 12080
        c['dns']['docker_bridge_ip'] = '172.19.0.1'
        c['dns']['servers'] = ['1.1.1.1#cloudflare-dns.com']
        c['incus']['guest_user'] = 'coder'
        with tempfile.TemporaryDirectory() as tmp:
            config_file = pathlib.Path(tmp, 'config.json')
            config_file.write_text(json.dumps(c))
            c = configure.load_config(config_file)
        files = configure.all_guest_files(c)
        nft = files['/opt/proxyvm/files/etc/nftables/proxyvm.nft'].decode()
        self.assertIn('10.42.13.0/24', nft)
        self.assertIn('10.42.99.30/32', nft)
        self.assertIn('eth0', nft)
        self.assertIn('tcp dport 9050', nft)
        self.assertIn('redirect to :12080', nft)
        self.assertNotIn('10.77.88.1', nft)
        self.assertEqual(json.loads(files['/opt/proxyvm/files/etc/docker/daemon.json'])['bip'], '172.19.0.1/16')
        env = files['/opt/proxyvm/config/guest.env'].decode()
        self.assertIn('GUEST_USER=coder', env)
        self.assertIn('TOOL_PLAYWRIGHT=1', env)
        self.assertIn('1.1.1.1#cloudflare-dns.com', files['/opt/proxyvm/files/etc/systemd/resolved.conf.d/90-proxyvm-dot.conf'].decode())

    def test_render_roundtrip(self):
        try:
            import yaml
        except ImportError:
            self.skipTest('Optional PyYAML unavailable; installed by CI')
        with tempfile.TemporaryDirectory() as tmp:
            folder = pathlib.Path(tmp)
            key = folder / 'public.pub'
            key.write_text('ssh-ed25519 ' + base64.b64encode(bytes(range(32))).decode() + ' test@example.invalid\n')
            output = folder / 'data.yaml'
            configure.render_cloud_init(self.config, 'test-vm', str(key), str(output))
            text = output.read_text()
            self.assertTrue(text.startswith('#cloud-config\n'))
            data = yaml.safe_load(text)
            self.assertEqual(data['users'][0]['name'], 'dev')
            self.assertEqual(data['runcmd'][0], ['bash', '/opt/proxyvm/bootstrap/entrypoint.sh'])
            original = configure.all_guest_files(self.config)
            decoded = {item['path']: base64.b64decode(item['content']) for item in data['write_files']}
            self.assertEqual(decoded, original)
            self.assertNotIn('/var/home/', text)

    def test_reject_credentials(self):
        c = copy.deepcopy(self.config)
        c['proxy']['api_token'] = 'anything'
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp, 'config.json')
            path.write_text(json.dumps(c))
            with self.assertRaises(ValueError):
                configure.load_config(path)

    def test_services_have_no_comments(self):
        for unit in (configure.ROOT / 'files/etc/systemd/system').glob('*.service'):
            for line in unit.read_text().splitlines():
                self.assertFalse(line.lstrip().startswith('#'), str(unit))

    def test_no_private_artifacts(self):
        root = configure.ROOT
        self.assertFalse((root / 'reference').exists())
        self.assertIn('config.json', (root / '.gitignore').read_text())
        for folder in ('bootstrap', 'tools', 'files'):
            for file in (root / folder).rglob('*'):
                if file.is_file():
                    content = file.read_text()
                    self.assertNotIn('-----BEGIN PRIVATE KEY-----', content)
                    self.assertNotIn('-----BEGIN OPENSSH PRIVATE KEY-----', content)



if __name__ == '__main__':
    unittest.main()
