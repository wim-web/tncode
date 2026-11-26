"""Build the offline feature search and the dimension-only panel illustrations."""
import csv
import html
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def table(relative):
    with (ROOT / relative).open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))

def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")

def main():
    features = table("inventory/features.tsv")
    entries = table("inventory/entries.tsv")
    live = table("inventory/runtime-entries.tsv")
    transitions = table("results/transitions.tsv")
    runtime = table("comparison/runtime-only.tsv")
    data = {
        "columns": list(features[0]),
        "features": [list(r.values()) for r in features],
        "entries": [[r[k] for k in ("id","feature_id","kind","name","source")] for r in entries],
        "live": [[r[k] for k in ("live_entry_id","feature_id","screen","role")] for r in live],
        "runtime": runtime,
        "results": transitions,
    }
    template = (ROOT / "methods/viewer-template.html").read_text()
    (ROOT / "index.html").write_text(template.replace("__PUBLIC_DATA__", encode(data)))

    source = table("screens/panel-measurements.tsv")
    pictures=[]
    names={"draft":"下書き","details":"スレッド詳細","right":"作業用右パネル"}
    for r in source:
        w=int(r["viewport"]); mode=r["state"]
        x,y,ew,eh=[float(r[k]) for k in ("x","y","width","height")]
        svg=[f'<svg xmlns="http://www.w3.org/2000/svg" role="img" aria-label="{w} px {names[mode]}" viewBox="0 0 {w} 720">']
        def box(x,y,width,height,label,fill):
            svg.append(f'<rect x="{x}" y="{y}" width="{width}" height="{height}" fill="{fill}" stroke="#8a99a6"/>')
            svg.append(f'<text x="{x+8}" y="{y+21}" fill="#19232b" font-size="15">{html.escape(label)}</text>')
        box(0,0,w,720,"","#f4f7f7")
        box(0,0,257,720,"スレッド一覧","#dce8ed")
        box(257,0,w-257,52,"プロジェクト / スレッド","#e4ece6")
        box(x,y,ew,eh,f"入力欄 {ew:g} px","#e4f2d6")
        if w==1080 and mode=="details":box(780,52,296,247,"詳細","#fbe5c6")
        svg.append("</svg>")
        pictures.append('<figure><figcaption>'+f'{w} × 720 ・ {names[mode]}　入力 x={x:g}, y={y:g}, 幅={ew:g}'+'</figcaption>'+''.join(svg)+'</figure>')
    page='''<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>パネルと入力の実測配置</title><style>body{font:16px/1.55 system-ui,sans-serif;max-width:1350px;margin:20px auto;padding:0 12px}section{display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:12px}figure{margin:0}svg{display:block;width:100%;height:auto}figcaption{font-size:14px}</style><h1>パネルと入力欄の配置</h1><p>色は領域を識別するための説明用。入力欄は各条件の実測値で描いた。右パネルを開いた状態も入力欄の変化を比較する図で、表にないパネルの境界は省略した。</p><p><a href="panel-measurements.tsv">数値表</a> ・ <a href="source/README.md">全画面の仕様</a></p><section>'''
    (ROOT / "screens/layout.html").write_text(page+"\n".join(pictures)+"</section></html>")
if __name__=="__main__":main()
