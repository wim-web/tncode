import argparse
import datetime
import json
import os
import pathlib
import sqlite3
import subprocess

p=argparse.ArgumentParser()
p.add_argument("root",type=pathlib.Path)
p.add_argument("label",choices=["before-restart","after-restart","after-failure","after-repair","v2-before","v2-after"])
args=p.parse_args()
assert (args.root/"audit-owned").read_text()=="t3-0.1.12\n"
database=args.root/"state/userdata/statev2.sqlite"
con=sqlite3.connect(database.resolve().as_uri()+"?mode=ro",uri=True)
con.row_factory=sqlite3.Row
def rows(query):
    return [dict(r) for r in con.execute(query)]
data={
    "label":args.label,"at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "pid":int((args.root/"fixture.pid").read_text()),
    "source":"isolated T3CODE_HOME/userdata/statev2.sqlite (read-only transaction)",
    "projects":rows("SELECT project_id,title,workspace_root,archived_at FROM projection_projects"),
    "threads":rows("""SELECT thread_id,project_id,title,runtime_mode,archived_at,
        json_extract(payload_json,'$.branch') AS branch,json_extract(payload_json,'$.worktreePath') AS worktree_path,
        active_provider_thread_id FROM orchestration_v2_projection_threads ORDER BY created_at"""),
    "runs":rows("""SELECT thread_id,run_id,ordinal,status,provider_thread_id FROM orchestration_v2_projection_runs ORDER BY requested_at"""),
    "messages":rows("""SELECT json_extract(payload_json,'$.threadId') AS thread_id,
        json_extract(payload_json,'$.role') AS role,COUNT(DISTINCT json_extract(payload_json,'$.id')) AS message_count
        FROM orchestration_events WHERE event_type='message.updated' GROUP BY 1,2"""),
    "events":rows("""SELECT sequence,occurred_at,event_type,stream_id,
        json_extract(payload_json,'$.id') AS entity_id,json_extract(payload_json,'$.threadId') AS thread_id,
        json_extract(payload_json,'$.status') AS status,json_extract(payload_json,'$.branch') AS branch,
        json_extract(payload_json,'$.worktreePath') AS worktree_path
        FROM orchestration_events WHERE event_type IN ('thread.created','thread.metadata-updated','run.created','run.updated','provider-session.attached') ORDER BY sequence"""),
    "git":{},
}
for repo in (args.root/"Audit Project",args.root/"Conflict Project"):
    if not (repo/".git").exists():continue
    data["git"][repo.name]={}
    for name,command in (("worktrees",["worktree","list","--porcelain"]),("status",["status","--short","--branch"])):
        data["git"][repo.name][name]=subprocess.check_output(["git","-C",repo,*command],text=True)
out=pathlib.Path(os.environ.get("T3_AUDIT_OUTPUT",args.root/"receipts"))/(args.label+".json")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(data,indent=2)+"\n")
