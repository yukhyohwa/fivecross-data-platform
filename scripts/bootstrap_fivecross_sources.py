"""Mirror only verified FiveCross SQL/case sources.

Never reads or copies the external backup repository. Validates every candidate
and writes a manifest before changing the local mirror; rejects abort the run.
"""
from __future__ import annotations
import hashlib, json, os, shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
HOME=Path(os.environ.get("FIVECROSS_GITHUB_ROOT", "C:/Users/5xgames/Desktop/github"))
SQL_SRC=HOME/"fivecross-sql-lib"/"games"; CASES_SRC=HOME/"fivecross-analysis-cases"; EVENTS_SRC=HOME/"shinchan-events-tracking"
ALIYUN_BACKUP_SRC=HOME/"fivecross-aliyun-backup"; SQL_DST=ROOT/"sql"; DOC_DST=ROOT/"knowledge"/"docs"
MANIFEST_PATH=ROOT/"config"/"fivecross-source-manifest.json"
_REJECTED_MARKERS=("joytools","joydata","hlhy_data_ai","欢乐互娱","starrocks","mysql","dm_platform_config","joydata_wh")

def _game_key(k):
    return {"slam_dunk":"slam_dunk_gl","crayon_shinchan":"crayon_shinchan_tc","jump_assemble":"jump_assemble_tc","kurokos_basketball":"kuroko_basketball_jp","street_rivals":"street_rivals_jp","captain_tsubasa":"captain_tsubasa_global","new_three_kingdoms":"new_three_kingdoms_global","saint_seiya2":"saint_seiya2_tc","saint_seiya3":"saint_seiya3_global"}.get(k,k)

def _reason(p):
    text=p.read_text(encoding="utf-8",errors="replace").lower()
    for marker in _REJECTED_MARKERS:
        if marker in text or marker in p.name.lower(): return f"rejected marker: {marker}"
    return None

def _candidates():
    out=[]
    for kind,base,pattern in (("sql",SQL_SRC,"*.sql"),("case",CASES_SRC,"*.md"),("event",EVENTS_SRC,"*.md")):
        if base.exists(): out.extend((kind,p) for p in sorted(base.rglob(pattern)) if not any(x in {".git","node_modules"} for x in p.parts))
    return out

def build_manifest():
    accepted=[]; rejected=[]
    for kind,src in _candidates():
        item={"kind":kind,"source":src.relative_to(HOME).as_posix(),"sha256":hashlib.sha256(src.read_bytes()).hexdigest()}
        why=_reason(src)
        (rejected if why else accepted).append({**item, **({"reason":why} if why else {})})
    return {"manifest_version":1,"source_type":"FiveCross","policy":"verified canonical repositories only; no external backup copy","sources":[str(SQL_SRC),str(CASES_SRC),str(EVENTS_SRC)],"external_backup_observed":ALIYUN_BACKUP_SRC.exists(),"accepted":accepted,"rejected":rejected}

def _destination(kind,src):
    if kind=="sql":
        rel=src.relative_to(SQL_SRC); game=rel.parts[0] if len(rel.parts)>1 else "common"; return SQL_DST/f"fivecross_{game}_{'_'.join(rel.parts[1:] if len(rel.parts)>1 else rel.parts)}",_game_key(game)
    rel=src.relative_to(HOME); name="fivecross_"+"_".join(rel.with_suffix("").parts); game=rel.parts[1] if len(rel.parts)>2 and rel.parts[0]=="fivecross-analysis-cases" else "shared"; return DOC_DST/f"{name}.md",_game_key(game)

def sync():
    manifest=build_manifest(); MANIFEST_PATH.parent.mkdir(parents=True,exist_ok=True); MANIFEST_PATH.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    if manifest["rejected"]: raise RuntimeError(f"source validation failed; rejected={len(manifest['rejected'])}")
    counts={"sql_files":0,"doc_files":0}
    for item in manifest["accepted"]:
        src=HOME/item["source"]; dst,game=_destination(item["kind"],src); dst.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(src,dst)
        meta={"version":1,"source_type":"FiveCross","game":game,"source":item["source"],"sha256":item["sha256"]}; Path(str(dst)+".json").write_text(json.dumps(meta,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
        counts["sql_files" if item["kind"]=="sql" else "doc_files"]+=1
    return {**counts,"manifest":str(MANIFEST_PATH),"rejected":0,"backup_copied":False}

def main():
    if not SQL_SRC.exists(): raise SystemExit(f"Missing SQL source: {SQL_SRC}")
    print(json.dumps(sync(),ensure_ascii=False))
if __name__=="__main__": main()
