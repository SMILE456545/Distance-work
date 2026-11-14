# -*- coding: utf-8 -*-
"""One-time setup for connecting to RemoteDesk from anywhere (without Tailscale):
DuckDNS name + HTTPS (Caddy) + Windows firewall. Run: setup-internet.bat"""
import json
import os
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "config.json")
BIN = os.path.join(HERE, "bin")
CADDY = os.path.join(BIN, "caddy.exe")
CADDY_URL = ("https://caddyserver.com/api/download?os=windows&arch=amd64"
             "&p=github.com%2Fcaddy-dns%2Fduckdns")


def line(t=""):
    print(t, flush=True)


def load():
    with open(CONFIG, encoding="utf-8") as f:
        return json.load(f)


def save(cfg):
    with open(CONFIG, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


def main():
    if not os.path.exists(CONFIG):
        line("Сначала один раз запустите сервер (start-server.bat), потом этот файл.")
        return
    cfg = load()
    line("=" * 64)
    line("  RemoteDesk — доступ из любого места без Tailscale")
    line("=" * 64)
    line()
    line("ШАГ 1. DuckDNS — бесплатное постоянное имя для ноутбука")
    line("  1) Откройте https://www.duckdns.org и войдите (через Google, GitHub…)")
    line("  2) В поле «sub domain» придумайте имя, например  myhome-pc, нажмите «add domain»")
    line("  3) Вверху страницы скопируйте «token» (длинная строка с дефисами)")
    line()
    name = input(f"  Имя на DuckDNS [{cfg.get('domain') or 'например myhome-pc'}]: ").strip()
    if not name and cfg.get("domain"):
        name = cfg["domain"]
    name = name.lower().replace("https://", "").split("/")[0].split(":")[0]
    if not name:
        line("  Имя не введено — выходим.")
        return
    if not name.endswith(".duckdns.org"):
        name += ".duckdns.org"
    token = input("  Token с сайта DuckDNS" + (" [оставить прежний]" if cfg.get("duckdns_token") else "") + ": ").strip()
    token = token or cfg.get("duckdns_token", "")
    sub = name.split(".")[0]
    try:
        with urllib.request.urlopen(f"https://www.duckdns.org/update?domains={sub}&token={token}", timeout=15) as r:
            ok = r.read().strip() == b"OK"
    except Exception as e:
        line(f"  Не удалось связаться с DuckDNS: {e}")
        return
    if not ok:
        line("  DuckDNS ответил KO: проверьте имя (его нужно сначала добавить на сайте) и token.")
        return
    cfg["domain"], cfg["duckdns_token"] = name, token
    save(cfg)
    line(f"  Готово: {name} теперь указывает на этот ноутбук.")
    line()

    line("ШАГ 2. HTTPS (шифрование) — программа Caddy с сайта caddyserver.com")
    if os.path.isfile(CADDY):
        line("  Уже скачана.")
    else:
        os.makedirs(BIN, exist_ok=True)
        line("  Скачиваю (около 50 МБ)…")
        tmp = CADDY + ".part"
        urllib.request.urlretrieve(CADDY_URL, tmp)
        os.replace(tmp, CADDY)
        line("  Скачана.")
    out = subprocess.run([CADDY, "list-modules"], capture_output=True, text=True).stdout
    if "dns.providers.duckdns" not in out:
        line("  [!] В скачанной Caddy нет модуля DuckDNS — удалите server\\bin\\caddy.exe и запустите снова.")
        return
    line("  Сертификат Let's Encrypt Caddy получит и будет продлевать сама.")
    line()

    https, rtc = cfg.get("https_port", 8443), cfg.get("rtc_port", 8766)
    line("ШАГ 3. Брандмауэр Windows — откроются два порта")
    line("  Windows спросит разрешение администратора — нажмите «Да».")
    ps = (f"New-NetFirewallRule -DisplayName 'RemoteDesk HTTPS' -Direction Inbound -Protocol TCP "
          f"-LocalPort {https} -Action Allow -Profile Any | Out-Null; "
          f"New-NetFirewallRule -DisplayName 'RemoteDesk video' -Direction Inbound -Protocol UDP "
          f"-LocalPort {rtc} -Action Allow -Profile Any | Out-Null")
    # old rules are removed first, so running this file again doesn't pile them up
    elevated = (f"Get-NetFirewallRule -DisplayName 'RemoteDesk HTTPS','RemoteDesk video' -EA 0 | "
                f"Remove-NetFirewallRule; {ps}")
    subprocess.run(["powershell", "-NoProfile", "-Command",
                    "Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden "
                    f"-ArgumentList '-NoProfile','-Command',\"{elevated}\""])
    check = subprocess.run(["powershell", "-NoProfile", "-Command",
                            "(Get-NetFirewallRule -DisplayName 'RemoteDesk HTTPS','RemoteDesk video' -EA 0).Count"],
                           capture_output=True, text=True).stdout.strip()
    line("  Порты открыты." if check == "2" else "  [!] Правила не добавились (не нажали «Да»?). Запустите файл ещё раз.")
    line()

    ip = "<IP ноутбука>"
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
    except OSError:
        pass
    line("ШАГ 4. Роутер — это нужно сделать вам, один раз")
    line("  1) Откройте в браузере адрес роутера (обычно http://192.168.1.1 или http://192.168.0.1) и войдите (логин/пароль на наклейке роутера)")
    line("  2) Раздел  Application → Port Forwarding  (Приложения → Переадресация портов)")
    line("  3) Добавьте два правила:")
    line(f"       Имя RemoteDesk-HTTPS   протокол TCP   внешний порт {https}   внутренний IP {ip}   внутренний порт {https}")
    line(f"       Имя RemoteDesk-video   протокол UDP   внешний порт {rtc}   внутренний IP {ip}   внутренний порт {rtc}")
    line("  4) Чтобы адрес ноутбука не менялся: LAN → DHCP Binding (Привязка DHCP) —")
    line(f"     закрепите {ip} за этим ноутбуком.")
    line()
    line("ГОТОВО. Перезапустите сервер (start-server.bat). На телефоне откройте:")
    line(f"     https://{name}:{https}")
    line("  Первое получение сертификата занимает до минуты.")
    line("=" * 64)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    input("\nНажмите Enter, чтобы закрыть…")
