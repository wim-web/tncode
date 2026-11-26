#!/usr/bin/python3
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Set up a disposable T3 fixture root.")
    parser.add_argument("run", type=Path, help="An existing empty directory created by mktemp")
    args = parser.parse_args()
    if args.run.is_symlink():
        parser.error("Use an empty directory created by mktemp.")
    run = args.run.resolve()
    if not run.is_dir() or any(run.iterdir()):
        parser.error("Use an empty directory created by mktemp.")

    peer = Path(__file__).resolve().with_name("codex-fixture")
    state_dir = run / "userdata"
    codex_home = run / "codex-home"
    for directory in (state_dir, codex_home, run / "project"):
        directory.mkdir(mode=0o700)
    (codex_home / ".t3-turn-fixture").touch(mode=0o600, exist_ok=False)

    other_drivers = (
        "acpRegistry", "antigravity", "claudeAgent", "cursor", "fx", "grok",
        "kiro", "muse", "opencode", "pi",
    )
    providers = {driver: {"driver": driver, "enabled": False} for driver in other_drivers}
    providers["codex"] = {
        "driver": "codex",
        "displayName": "Codex Turn Fixture",
        "enabled": True,
        "config": {
            "setupMode": "existing",
            "binaryPath": str(peer),
            "homePath": str(codex_home),
        },
    }
    settings = state_dir / "settings.json"
    with settings.open("x", encoding="utf-8") as output:
        json.dump({"providerInstances": providers}, output, indent=2)
        output.write("\n")
    print(settings)


if __name__ == "__main__":
    main()
