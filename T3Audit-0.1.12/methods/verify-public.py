"""Validate the public handoff in a fresh recursive checkout. Read-only, no network."""
import collections
import csv
import hashlib
import json
import math
import re
import subprocess
import urllib.parse
from functools import lru_cache
from pathlib import Path

AUDIT = Path(__file__).resolve().parents[1]
ROOT = AUDIT.parent
UPSTREAM = AUDIT / ".source"
NATIVE = ROOT / "PiWorkspace"
GROUPS = ("NAV", "CHAT", "DEV", "CFG", "HOST", "RPC", "UI")

def rows(file):
    with file.open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream,delimiter="\t"))

def indexed(file, key="id"):
    values = rows(file)
    result = {v[key]:v for v in values}
    assert len(result)==len(values), f"duplicate {key} in {file}"
    return result

@lru_cache(None)
def lines(path):
    return len(path.read_bytes().splitlines())

def pointers(base, value):
    for s in value.split("|"):
        if not s.strip() or s.strip()=="-":continue
        m=re.fullmatch(r"(.+?):L?(\d+)(?:[-–]L?(\d+))?",s.strip())
        assert m, s
        p=(base/m[1]).resolve()
        assert p.is_relative_to(base) and p.is_file(),s
        assert 1<=int(m[2])<=int(m[3] or m[2])<=lines(p),s

def git(*args):
    return subprocess.check_output(["git",*args],text=True).strip()

def main():
    frozen=json.loads((AUDIT/"inventory/freeze.json").read_text())
    assert git("-C",str(UPSTREAM),"rev-parse","HEAD")==frozen["commit"],"Run git submodule update --init --recursive"
    features=indexed(AUDIT/"inventory/features.tsv")
    entries=indexed(AUDIT/"inventory/entries.tsv")
    live=indexed(AUDIT/"inventory/runtime-entries.tsv","live_entry_id")
    rt=indexed(AUDIT/"comparison/runtime-only.tsv")
    assert len(features)==3072 and len(entries)==10763 and len(live)==1091 and len(rt)==2
    for group in GROUPS:
        directory=AUDIT/"inventory"/group
        for filename,expected in frozen["sha256"][group].items():
            assert hashlib.sha256((directory/filename).read_bytes()).hexdigest()==expected,(group,filename)
        original=indexed(directory/"features.tsv")
        native=indexed(AUDIT/"comparison"/(group+".tsv"))
        assert set(original)==set(native)=={f for f in features if f.startswith(group+"-")}
        for r in native.values():pointers(NATIVE,r["swift_source"])
    for r in features.values():pointers(UPSTREAM,r["source"])
    for r in entries.values():
        assert r["feature_id"] in features,r["id"]
        pointers(UPSTREAM,r["source"])
    for r in live.values():
        assert r["feature_id"] in features.keys() | rt.keys(),r
        assert r["entry_id"]=="-" or entries[r["entry_id"]]["feature_id"]==r["feature_id"],r
    states=indexed(AUDIT/"screens/states.tsv","screen_id")
    assert len(states)==61 and states.keys()==indexed(AUDIT/"comparison/screens.tsv","state_id").keys()
    captures=indexed(AUDIT/"screens/captures.tsv","capture_id")
    assert len(captures)==181
    native_caps=indexed(AUDIT/"screens/swift-captures.tsv","capture_id")
    assert len(native_caps)==13
    for r in states.values():
        assert (AUDIT/r["source_ref"].split("#")[0]).is_file(),r["source_ref"]
        assert all(v in captures for v in r["geometry_capture_ids"].split("|") if v)
    for file,keys in (("geometry.tsv",captures),("swift-geometry.tsv",native_caps)):
        data=rows(AUDIT/"screens"/file)
        assert {r["capture_id"] for r in data}==set(keys)
        assert all(all(math.isfinite(float(r[k])) for k in ("x","y","width","height")) for r in data)
    transitions=rows(AUDIT/"results/transitions.tsv")
    for r in transitions:
        assert r["feature_id"] in features
        assert r["entry_id"]=="-" or entries[r["entry_id"]]["feature_id"]==r["feature_id"]
        assert all(cid in captures for cid in r["geometry_capture_ids"].split("|") if cid)
    operations={k:v for k,v in features.items() if not k.startswith(("RPC-","UI-"))}
    levels=collections.Counter(r["t3_verification"] for r in operations.values())
    assert dict(levels)==json.loads((AUDIT/"inventory/summary.json").read_text())["workflow_evidence_levels"]
    assert {r["id"] for r in rows(AUDIT/"inventory/unverified.tsv")}=={k for k,v in operations.items() if v["t3_verification"]!="記載した遷移を実行"}
    source=(NATIVE/"Sources/PiWorkspace/PiProcess.swift").read_text()
    assert '"PI_TELEMETRY": "0"' in source
    result=json.loads((AUDIT/"results/pi-telemetry.json").read_text())
    assert result["nativeDefault"]=={"installReporting":False,"attributionEnabled":False}
    assert result["enabledControl"]=={"installReporting":True,"attributionEnabled":True}

    files=git("-C",str(ROOT),"ls-files","-z").strip("\x00").split("\x00")
    links=0
    for name in files:
        p=ROOT/name
        if p.suffix!=".md":continue
        for href in re.findall(r"\]\(([^)]+)\)",p.read_text()):
            u=urllib.parse.urlsplit(href.strip("<>"))
            if u.scheme or not u.path:continue
            target=(p.parent/urllib.parse.unquote(u.path)).resolve()
            assert target.is_relative_to(ROOT) and target.exists(),f"{name}: {href}"
            links+=1
    print(f"Verified {len(features)} source rows, {len(entries)} registrations, {len(live)} runtime IDs, "
          f"{len(states)} screen specifications, {len(captures)} renderer and {len(native_caps)} native geometry samples, "
          f"{len(transitions)} transition records, and {links} local Markdown links.")
if __name__=="__main__":main()
