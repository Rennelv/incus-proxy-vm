# Incus Cloud Proxy VM

Fedora Cloud VM в Incus, весь исходящий IPv4 TCP которой идёт через внешний SOCKS5-прокси (Redsocks + nftables). DNS через DoT, Docker и rootless Podman, набор dev-инструментов настраивается в конфиге.

Прокси должен работать вне ВМ и быть доступен гостю по IPv4. Поддерживается SOCKS5 без аутентификации, UDP не проксируется.

```text
Fedora Cloud VM
  приложения / Docker / rootless Podman
    ├─ DNS → systemd-resolved → DoT TCP/853
    └─ TCP → nftables redirect → Redsocks → SOCKS5 (напр. IP моста:10808) → цель
  nftables гостя: исходящее по умолчанию drop, IPv6/UDP заблокированы кроме DHCP
           ↓
  ACL на NIC моста Incus: ограничение исходящего со стороны хоста
```

Порядок установки: DNF через явный SOCKS5, прозрачный редирект, DNS и контейнеры, инструменты, проверки, SELinux relabel, `Enforcing`, перезагрузка. `READY` выставляется после проверок на последней загрузке.

Требования: Linux-хост с KVM, Incus и storage pool; Python 3, Bash, `sudo`, публичный SSH-ключ; `images:fedora/44/cloud` или совместимый образ с `cloud-init`, `systemd-networkd` и Incus Agent.

## Установка

### 1. Incus

[Установите Incus](https://linuxcontainers.org/incus/docs/main/installing/). На ненастроенном хосте:

```bash
sudo incus admin init
incus storage list
incus remote list
```

Если remote `images` нет: `incus remote add images https://images.linuxcontainers.org --protocol=simplestreams`.

### 2. SOCKS5

Запустите SOCKS5 на адресе, доступном из ВМ. В примере мост `10.77.88.1/24`, прокси слушает `10.77.88.1:10808` (не `127.0.0.1`). Закройте его от остальных сетей.

```bash
curl -fsS --proxy socks5h://10.77.88.1:10808 https://example.org -o /dev/null
```

### 3. Конфиг

```bash
git clone <URL> incus-cloud-proxy
cd incus-cloud-proxy
cp config.example.json config.json
$EDITOR config.json
python3 configure.py --config config.json validate
```

| Раздел | Настройки |
| --- | --- |
| `incus` | образ, имена bridge/ACL/profile, storage pool, vCPU/RAM/disk, интерфейс гостя, пользователь |
| `proxy` | адрес/порт SOCKS5, порт локального редиректа |
| `dns` | DoT-серверы, IP Docker DNS на мосту, проверочный домен |
| `packages` | RPM-пакеты по этапам: network/containers/development/browser |
| `tools` | pnpm, bun, uv, Claude Code, Codex, OpenCode, Antigravity, Playwright, X11; URL установщиков и npm-пакеты |

Не удаляйте из групп пакетов системные зависимости этапов, иначе bootstrap упадёт на проверке. Интерфейс по умолчанию `enp5s0`, иначе поменяйте `incus.guest_interface`.

### 4. Сеть, ACL, профиль

```bash
./setup-host.sh --plan
./setup-host.sh --apply
```

`--apply` создаёт bridge (IPv4 DHCP/NAT, без IPv6), ACL (исходящий TCP только к SOCKS5, входящий SSH только с шлюза моста) и профиль. Существующие объекты не перезаписываются. Если они уже есть, пропустите шаг и проверьте ACL вручную.

### 5. ВМ

```bash
./create-vm.sh proxy-test
./create-vm.sh proxy-test "$HOME/projects/workspace"   # с virtiofs-каталогом, доступным гостю на запись
SSH_PUBKEY="$HOME/.ssh/other_key.pub" ./create-vm.sh proxy-test
PROJECT_CONFIG=/path/to/config.json ./create-vm.sh proxy-test
```

Только сгенерировать cloud-init:

```bash
python3 configure.py --config config.json render proxy-test "$HOME/.ssh/id_ed25519.pub" rendered/proxy-test.yaml
```

### 6. Ожидание `READY`

```bash
./status-vm.sh proxy-test
```

ВМ несколько раз перезагружается; `VM agent isn't currently running` в это время нормально. `cloud-init status: done` ещё не конец: ждите `READY` и `SELinux: Enforcing`.

Диагностика:

```bash
/usr/bin/sudo incus exec proxy-test -- tail -n 100 /var/log/proxyvm-bootstrap.log
/usr/bin/sudo incus exec proxy-test -- tail -n 100 /var/log/proxyvm-finalize.log
/usr/bin/sudo incus exec proxy-test -- journalctl -u proxyvm-finalize --no-pager
/usr/bin/sudo incus console proxy-test --show-log
```

При `FAILED` перезагрузок больше не будет. После исправления: `sudo bash /opt/proxyvm/tools/retry-finalization.sh`. Если нет `bootstrap.done`: `sudo bash /opt/proxyvm/bootstrap/entrypoint.sh` (готовые этапы пропускаются).

### 7. Проверка killswitch

```bash
ssh dev@VM_IPV4
bash /opt/proxyvm/tools/check-killswitch.sh
```

Тест временно останавливает Redsocks и может оборвать SSH. Проверяет только отказ TCP, не DNS/UDP-утечки.

## Очистка после установки

Только вручную, после `READY`. В ВМ:

```bash
sudo bash /opt/proxyvm/tools/cleanup-installation.sh
```

На хосте:

```bash
./detach-seed.sh proxy-test
```

Удаляются установочные скрипты, копии user-data и логи установки; seed отключается только у этой ВМ (или перекрывается `type: none`), `cloud-init.user-data` сбрасывается. Если ISO не отключается на ходу, перезагрузите ВМ. Это не затирает диск и не скрывает конфигурацию от root. `cloud-init clean` не используйте.

## Ограничения

- Проксируется только IPv4 TCP. UDP/ICMP/IPv6 наружу заблокированы (QUIC, NTP, IPv6-only не работают).
- DoT идёт по тому же прокси. Docker использует локальный resolver на мосту, rootless Podman свой.
- У ACL моста есть [исключения](https://linuxcontainers.org/incus/docs/main/howto/network_acls/) для базовых сервисов.
- Пользователь гостя имеет `NOPASSWD:ALL`.
- Установщики CLI скачиваются по HTTPS без фиксации версий и хешей.
- `rendered/*.yaml` содержит ваш публичный ключ и исключён из Git.

## Структура

```text
config.example.json  пример конфига
configure.py         проверка конфига и генерация cloud-init
setup-host.sh        bridge, ACL, профиль
create-vm.sh         создание ВМ
status-vm.sh         статус
detach-seed.sh       отключение seed
bootstrap/           этапы установки и финализация
files/etc/           конфиги гостя
tools/               проверки, повтор финализации, очистка
```
