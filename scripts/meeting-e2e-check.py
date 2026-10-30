"""Checks a --meeting-selftest report against the corpus truth. Standard library only."""

import difflib
import json
import os
import re
import subprocess
import sys

report = json.load(open(sys.argv[1]))
corpus = json.load(open(sys.argv[2]))
truth = corpus["segments"]
length = corpus["duration"]
record = report.get("record") or {}
folder = report.get("folder", "")


def norm(s):
    return re.sub(r"[\W_]+", "", s).lower()


def best_line(sentence, lines):
    """The live line that contains most of the sentence, and how much of it (0-1)."""
    target = norm(sentence)
    best, score = None, 0.0
    for line in lines:
        m = difflib.SequenceMatcher(None, target, norm(line["text"]))
        covered = sum(b.size for b in m.get_matching_blocks()) / max(1, len(target))
        if covered > score:
            best, score = line, covered
    return best, score


lines = record.get("lines", [])
matched, correct, single, single_ok = 0, 0, 0, 0
rows = []
for seg in truth:
    line, score = best_line(seg["text"], lines)
    want = "me" if seg["speaker"] == "me" else "them"
    ok = score >= 0.6
    matched += ok
    label_ok = ok and line["side"] == want
    correct += label_ok
    # Live hears one mixed stream, so a sentence spoken over someone else has no reliable side until the
    # offline pass; the label check counts the sentences with one voice at a time.
    overlapped = any(o is not seg and not (o["end"] <= seg["start"] or o["start"] >= seg["end"]) for o in truth)
    if ok and not overlapped:
        single += 1
        single_ok += label_ok
    rows.append(f"  {'ok ' if label_ok else ('LBL' if ok else 'MIS')} {want:4s} {score:.2f}{' (overlap)' if overlapped else ''} {seg['text'][:28]}")
offline_me = [s for s in record.get("segments", []) if s["speaker"] == "me"]
me_truth = [s for s in truth if s["speaker"] == "me"]
offline_me_hits = sum(best_line(s["text"], offline_me)[1] >= 0.6 for s in me_truth)

segments = record.get("segments", [])
speakers = record.get("speakers", {})
others = {speakers.get(s["speaker"], s["speaker"]) for s in segments if s["speaker"] != "me"}
notes_md = open(os.path.join(folder, "notes.md")).read() if folder and os.path.exists(os.path.join(folder, "notes.md")) else ""


def duration(path):
    try:
        out = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
        return float(re.search(r"estimated duration: ([\d.]+)", out).group(1))
    except Exception:
        return 0.0


mic_s = duration(os.path.join(folder, "audio/mic.m4a"))
browser_s = duration(os.path.join(folder, "audio/browser.m4a"))
files = ["meeting.json", "notes.md", "transcript.md", "audio/mic.m4a", "audio/browser.m4a"]
checks = {
    "no error, finished in time": not report.get("error") and not report.get("timedOut"),
    f"live transcript covers >= 10 of {len(truth)} sentences ({matched})": matched >= 10,
    f"live me/them label right on every single-voice sentence ({single_ok}/{single}; all: {correct}/{matched})": single and single_ok == single,
    f"offline 'me' track has all {len(me_truth)} of my sentences, double talk included ({offline_me_hits})": offline_me_hits == len(me_truth),
    f"rolled over to a new Live session ({record.get('liveSessions')} sessions)": record.get("liveSessions", 0) >= 2,
    f"running notes arrived during the meeting ({report.get('notesVersionsDuringMeeting')})": report.get("notesVersionsDuringMeeting", 0) >= 1,
    f"offline transcript has me and >= 2 other speakers ({sorted(others)})": any(s["speaker"] == "me" for s in segments) and len(others) >= 2,
    "notes.md has a to-do with an owner": bool(re.search(r"^- \[ \] .+ @\S+", notes_md, re.M)),
    "all five files written": all(os.path.exists(os.path.join(folder, f)) for f in files),
    f"both tracks as long as the meeting, {length:.0f} s (mic {mic_s:.1f}, browser {browser_s:.1f})": abs(mic_s - length) < 3 and abs(browser_s - length) < 3,
}
for name, ok in checks.items():
    print(("PASS " if ok else "FAIL ") + name)
print("sentences:")
print("\n".join(rows))
print("speakers:", speakers)
print("folder:", folder)
sys.exit(0 if all(checks.values()) else 1)
