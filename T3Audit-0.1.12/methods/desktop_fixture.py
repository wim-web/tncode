"""Prepare a scratch checkout and run the installed Electron app against its own shipped renderer."""
import argparse
import datetime
import hashlib
import http.server
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import threading

BASE = Path(__file__).resolve().parents[1]
APP = Path("/Applications/T3 Code (Beta).app/Contents")
ASAR = APP / "Resources/app.asar"
DEV_PROFILE = Path.home() / "Library/Application Support/t3code-dev"
LEGACY_DEV = DEV_PROFILE.with_name("T3 Code (Dev)")
DEBUG_PORT, SERVER_PORT, ASSET_PORT = 47861, 47862, 47863
FIXTURE_TEXT = "T3 audit sample.\n"

class Archive:
    def __init__(self):
        self.f = ASAR.open("rb")
        _, size, _, n = struct.unpack("<IIII", self.f.read(16))
        self.tree = json.loads(self.f.read(n))
        self.base = 8 + size

    def entry(self, name):
        e = self.tree
        for part in name.split("/"):
            e = e["files"][part]
        return e

    def read(self, e):
        self.f.seek(self.base + int(e["offset"]))
        return self.f.read(e["size"])

    def extract(self, e, dest):
        if "files" in e:
            dest.mkdir(exist_ok=True, parents=True)
            for name, child in e["files"].items():
                if name in (".", "..") or "/" in name: raise ValueError(name)
                self.extract(child, dest / name)
        elif "size" in e:
            if e["size"] == 0:
                dest.write_bytes(b"")
            else:
                dest.write_bytes(self.read(e))

def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for buf in iter(lambda: f.read(1<<20), b""): h.update(buf)
    return h.hexdigest()

def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()

def provenance():
    a = Archive()
    d = json.loads(a.read(a.entry("package.json")))
    with (APP / "Info.plist").open("rb") as f: plist = plistlib.load(f)
    git = ["git", "-C", str(BASE / ".source")]
    v = {
        "bundle":str(APP.parent), "bundle_id":plist["CFBundleIdentifier"],
        "short_version":plist["CFBundleShortVersionString"], "build":plist["CFBundleVersion"],
        "package_version":d["version"], "package_build":d["buildVersion"], "package_commit":d["t3codeCommitHash"],
        "checked_out_tag":command(*git,"describe","--exact-match","--tags","HEAD"),
        "commit":command(*git,"rev-parse","HEAD"), "upstream":"https://github.com/pingdotgg/t3code",
        "asar_sha256":sha(ASAR), "main_binary_sha256":sha(APP/"MacOS/T3 Code (Beta)"),
        "os":command("sw_vers"),"arch":platform.machine(),
        "electron":plistlib.loads((APP/"Frameworks/Electron Framework.framework/Resources/Info.plist").read_bytes())["CFBundleVersion"],
        "codesign":[l for l in command("codesign","-dv","--verbose=4",str(APP.parent)).splitlines() if l.startswith(("Identifier=","TeamIdentifier=","CDHash=","Format="))],
        "collected_at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    assert v["commit"].startswith(d["t3codeCommitHash"]) and v["checked_out_tag"]=="v0.1.12"
    (BASE/"evidence").mkdir(exist_ok=True)
    (BASE/"evidence/provenance.json").write_text(json.dumps(v,indent=2)+"\n")

def prep(root):
    root.mkdir(mode=0o700)
    (root/"audit-owned").write_text("t3-0.1.12\n")
    a=Archive()
    a.extract(a.entry("apps/server/dist/client"),root/"renderer")
    a.extract(a.entry("node_modules/playwright-core"),root/"playwright-core")
    project=root/"Audit Project"; project.mkdir()
    for args in (["init","-q","-b","main"],["config","user.name","Fixture"],["config","user.email","fixture@example.invalid"]):
        subprocess.run(["git","-C",project,*args],check=True)
    (project/"README.md").write_text(FIXTURE_TEXT)
    subprocess.run(["git","-C",project,"add","README.md"],check=True)
    subprocess.run(["git","-C",project,"commit","-qm","Baseline"],check=True)
    (project/"README.md").write_text(FIXTURE_TEXT+"Uncommitted fixture line.\n")
    (root/"profile").mkdir()
    state=root/"state/userdata";state.mkdir(parents=True)
    (state/"desktop-settings.json").write_text(json.dumps({"mainWindowBounds":{"x":40,"y":44,"width":1080,"height":720}}))
    (state/"settings.json").write_text(json.dumps({"providerInstances":{n:{"driver":n,"enabled":False} for n in ("codex","claudeAgent","pi","opencode","cursor","grok","fx","kiro","muse","antigravity")}}))

class Static(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        if not Path(self.translate_path(self.path)).is_file() and Path(self.path.split("?")[0]).suffix=="":
            self.path="/index.html"
        super().do_GET()

def run(root):
    assert (root/"audit-owned").read_text()=="t3-0.1.12\n"
    if LEGACY_DEV.exists(): raise SystemExit("Dev profile exists; stop.")
    for port in (DEBUG_PORT, SERVER_PORT, ASSET_PORT):
        with socket.socket() as s:
            s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
            s.bind(("127.0.0.1",port))
    if DEV_PROFILE.is_symlink() and DEV_PROFILE.resolve()==root/"profile": pass
    else: DEV_PROFILE.symlink_to(root/"profile",target_is_directory=True)  # fails atomically on existing data
    from functools import partial
    server=http.server.ThreadingHTTPServer(("127.0.0.1",ASSET_PORT),partial(Static,directory=str(root/"renderer")))
    threading.Thread(target=server.serve_forever,daemon=True).start()
    env={k:v for k,v in os.environ.items() if k in {"HOME","USER","LOGNAME","TMPDIR","LANG","PATH","SHELL","__CF_USER_TEXT_ENCODING","TERM","XPC_FLAGS","XPC_SERVICE_NAME"}}
    env.update(T3CODE_HOME=str(root/"state"),T3CODE_PORT=str(SERVER_PORT),VITE_DEV_SERVER_URL=f"http://127.0.0.1:{ASSET_PORT}",T3CODE_DISABLE_AUTO_UPDATE="true",DO_NOT_TRACK="1",T3CODE_TELEMETRY_ENABLED="false")
    args=[str(APP/"MacOS/T3 Code (Beta)"), f"--remote-debugging-port={DEBUG_PORT}","--remote-debugging-address=127.0.0.1","--lang=en-US","--force-device-scale-factor=1"]
    try:
        with (root/"desktop-private.log").open("ab") as log:
            p=subprocess.Popen(args,cwd=root,env=env,stdout=log,stderr=log)
        (root/"fixture.pid").write_text(str(p.pid))
        print("Isolated bundle PID",p.pid,flush=True)
        p.wait()
    finally:
        server.shutdown()
        if DEV_PROFILE.is_symlink() and DEV_PROFILE.resolve()==root/"profile": DEV_PROFILE.unlink()

def attach_turns(root):
    assert (root/"audit-owned").read_text()=="t3-0.1.12\n"
    fixture=root/"turn-peer"
    fixture.mkdir(mode=0o700)
    subprocess.run(["python3",BASE/"methods/turn-fixture/configure.py",fixture],check=True,stdout=subprocess.DEVNULL)
    target=root/"state/userdata/settings.json"
    existing=json.loads(target.read_text())
    existing.update(json.loads((fixture/"userdata/settings.json").read_text()))
    temp=target.with_name("settings.pending")
    temp.write_text(json.dumps(existing));temp.replace(target)

if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("action",choices=["prepare","run","provenance","attach-turns"]);p.add_argument("root",type=Path,nargs="?");args=p.parse_args()
    if args.action=="provenance":provenance()
    elif args.action=="prepare":prep(args.root.resolve())
    elif args.action=="attach-turns":attach_turns(args.root.resolve())
    else:run(args.root.resolve())
