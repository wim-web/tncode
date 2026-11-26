import argparse
import json
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument("fixture",type=Path)
p.add_argument("mode",choices=["block","restore"])
args=p.parse_args()
root=args.fixture.resolve()
assert (root/"audit-owned").read_text()=="t3-0.1.12\n"
config=root/"state/userdata/settings.json"
data=json.loads(config.read_text())
obstruction=root/"test-occupied-file"
if args.mode=="block":
    obstruction.write_text("fixture\n")
    data["worktreesDirectory"]=str(obstruction/"child")
else:
    assert data.get("worktreesDirectory")==str(obstruction/"child")
    data.pop("worktreesDirectory")
temp=config.with_suffix(".pending")
temp.write_text(json.dumps(data));temp.replace(config)
