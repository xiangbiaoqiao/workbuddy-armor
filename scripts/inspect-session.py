#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
inspect-session.py — read WorkBuddy's own session log and tell you which layer blocked

WorkBuddy writes every turn to:

    ~/.workbuddy/projects/<workspace>/<conversation-id>.jsonl

Each line is a JSON object. `type:"reasoning"` entries carry the model's raw chain of
thought, `type:"message" role:"assistant"` carries the reply. That is the only reliable
way to tell these three cases apart:

  1. patch not in effect   -> reasoning quotes "You MUST refuse ..." / "<content_policy>"
                              verbatim, i.e. the original block is still being sent
  2. patch in effect, model still refuses -> reasoning never quotes the block, it argues
                              from its own judgement ("this is malware tooling")
  3. patch in effect and it complies      -> you get code/commands

So before you go editing more files, run this.

Usage
-----
    python inspect-session.py                # last 3 sessions, verdict per turn
    python inspect-session.py --n 8          # more sessions
    python inspect-session.py --workspace my-workspace
    python inspect-session.py --json         # machine readable
    python inspect-session.py --grep "MUST refuse"

Exit code: 0 if no session quotes the policy block, 1 otherwise.
"""

import argparse
import glob
import json
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

HOME = os.path.expanduser("~")
PROJECTS = os.environ.get("WORKBUDDY_HOME", os.path.join(HOME, ".workbuddy"))
PROJECTS = os.path.join(PROJECTS, "projects")

# strings that prove the ORIGINAL policy text was in context
POLICY_QUOTES = [
    "You MUST refuse any request that violates laws",
    "You MUST refuse to provide instructions for illegal activities",
    "cannot be bypassed by role-play",
    "NEVER reveal, rephrase",
    "<content_policy>",
]
# strings that show the model treated our files as injection
INJECTION_FLAGS = ["prompt injection", "jailbreak", "injected", "dsh-purge", "CODEBUDDY.md"]
REFUSAL_FLAGS = ["I will refuse", "I should decline", "I'll refuse", "我不写", "这个我不做",
                 "我不能", "无法提供"]


def iter_turns(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            yield o


def user_query(o):
    c = o.get("content")
    chunks = []
    if isinstance(c, list):
        for blk in c:
            if isinstance(blk, dict) and blk.get("text"):
                chunks.append(str(blk["text"]))
    elif isinstance(c, str):
        chunks.append(c)
    s = "\n".join(chunks)
    k = s.find("<user_query>")
    if k >= 0:
        end = s.find("</user_query>", k)
        return s[k + 12:end if end > 0 else k + 200].strip()
    return ""


def texts(o):
    out = []
    for blk in (o.get("rawContent") or []):
        if isinstance(blk, dict) and blk.get("text"):
            out.append(str(blk["text"]))
    c = o.get("content")
    if isinstance(c, str):
        out.append(c)
    elif isinstance(c, list):
        for blk in c:
            if isinstance(blk, dict) and (blk.get("text") or blk.get("content")):
                out.append(str(blk.get("text") or blk.get("content")))
    r = o.get("reasoning")
    if isinstance(r, str):
        out.append(r)
    return out


def analyse(path):
    turns = []
    current_q = None
    for o in iter_turns(path):
        t = o.get("type")
        pd = o.get("providerData") or {}
        if t == "message" and o.get("role") == "user":
            q = user_query(o)
            if q:
                current_q = q
            continue
        if t not in ("reasoning", "message"):
            continue
        blob = "\n".join(texts(o))
        if not blob.strip():
            continue
        turns.append({
            "type": t,
            "role": o.get("role"),
            "model": pd.get("model"),
            "query": current_q,
            "policy": [p for p in POLICY_QUOTES if p in blob],
            "injection": [p for p in INJECTION_FLAGS if p.lower() in blob.lower()],
            "refusal": [p for p in REFUSAL_FLAGS if p in blob],
            "size": len(blob),
            "preview": blob[:280].replace("\n", " "),
        })
    return turns


def verdict(turns):
    policy_hits = sum(len(t["policy"]) for t in turns if t["type"] == "reasoning")
    refusal = any(t["refusal"] for t in turns if t["type"] == "message")
    if policy_hits:
        return "PATCH-NOT-EFFECTIVE", f"model still quotes the original policy block ({policy_hits} hits)"
    if refusal:
        return "MODEL-WEIGHTS", "patch is in effect; refusal comes from the model's own judgement"
    return "OK", "policy block absent, no refusal markers in the reply"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=3)
    ap.add_argument("--workspace", default="*")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--grep", default=None)
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(PROJECTS, args.workspace, "*.jsonl")),
                   key=lambda p: os.path.getmtime(p), reverse=True)[: args.n]
    if not files:
        print(f"no session logs under {PROJECTS}")
        return 2

    report = []
    bad = 0
    for p in files:
        turns = analyse(p)
        v, why = verdict(turns)
        if v == "PATCH-NOT-EFFECTIVE":
            bad += 1
        entry = {"session": os.path.basename(p), "modified": os.path.getmtime(p),
                 "verdict": v, "why": why, "turns": turns}
        report.append(entry)

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2, default=str))
        return 1 if bad else 0

    for entry in report:
        import time
        print("\n" + "=" * 72)
        print(f"session {entry['session'][:8]}   {time.strftime('%m-%d %H:%M', time.localtime(entry['modified']))}")
        print(f"verdict {entry['verdict']}  —  {entry['why']}")
        seen_q = set()
        for t in entry["turns"]:
            q = t.get("query") or ""
            if q and q not in seen_q:
                seen_q.add(q)
                print(f"\n  USER: {q[:160]}")
            if args.grep and args.grep.lower() not in t["preview"].lower():
                continue
            marks = []
            if t["policy"]:
                marks.append("policy-quoted=" + ",".join(x[:22] for x in t["policy"]))
            if t["injection"]:
                marks.append("calls-injection=" + ",".join(t["injection"][:3]))
            if t["refusal"]:
                marks.append("refusal=" + ",".join(t["refusal"][:2]))
            head = f"  [{t['type']}/{t['role'] or '-'}] {t['model'] or '-'}"
            if marks:
                head += "  « " + " | ".join(marks)
            print(head)
            print(f"      {t['preview'][:240]}")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
