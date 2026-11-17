# -*- coding: utf-8 -*-
"""Makes release\\RemoteDeskSetup.exe — the one file people download and click:
a small starter (setup\\Setup.cs) + release\\RemoteDesk.zip glued to its end.
The same file is the update package: the program reads the zip part of it."""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REL = os.path.dirname(HERE)
ZIP = os.path.join(REL, "RemoteDesk.zip")
OUT = os.path.join(REL, "RemoteDeskSetup.exe")
CSC = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), r"Microsoft.NET\Framework64\v4.0.30319\csc.exe")

src = open(os.path.join(REL, "..", "server", "launcher.py"), encoding="utf-8").read()
ver = re.search(r'^VERSION = "([\d.]+)"', src, re.M).group(1)
work = os.path.join(HERE, "work-setup")
os.makedirs(work, exist_ok=True)
with open(os.path.join(work, "Ver.cs"), "w", encoding="utf-8-sig") as f:
    f.write(f'''using System.Reflection;
[assembly: AssemblyTitle("RemoteDesk — управление компьютером с телефона")]
[assembly: AssemblyProduct("RemoteDesk")]
[assembly: AssemblyCompany("Kraken Digital")]
[assembly: AssemblyCopyright("© 2026 Kraken Digital")]
[assembly: AssemblyVersion("{ver}.0")]
[assembly: AssemblyFileVersion("{ver}.0")]
static class Ver {{ public const string V = "{ver}"; }}
''')
stub = os.path.join(work, "stub.exe")
r = subprocess.run([CSC, "/nologo", "/target:winexe", "/optimize+", "/codepage:65001",
                    "/win32icon:" + os.path.join(HERE, "remotedesk.ico"),
                    "/r:System.IO.Compression.dll", "/r:System.Windows.Forms.dll", "/r:System.Drawing.dll",
                    "/out:" + stub, os.path.join(HERE, "setup", "Setup.cs"), os.path.join(work, "Ver.cs")],
                   capture_output=True)
sys.stdout.buffer.write(r.stdout + r.stderr)
if r.returncode:
    sys.exit(1)
with open(OUT, "wb") as out:
    for part in (stub, ZIP):
        with open(part, "rb") as f:
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                out.write(chunk)
print(f"Done: {OUT} ({os.path.getsize(OUT) / 1e6:.1f} MB, version {ver})")
