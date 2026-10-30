"""Scores one extra recording against truth: levels of remote and me stretches, and Vertex/whisper recall.
ext_eval.py <dir> <name>   (reads <dir>/<name>.wav, aligned on the near track)"""

import json
import os
import pathlib
import subprocess
import sys

import numpy as np
import soundfile as sf

from evaluate import db, recall, window
from prep import offset_seconds
import transcribe_all as ta

work, name = pathlib.Path(sys.argv[1]), sys.argv[2]
segs = json.loads((work / "truth.json").read_text())["segments"]
near, sr = sf.read(work / "near.wav", dtype="float32")
rec, _ = sf.read(work / f"{name}.wav", dtype="float32")
off = offset_seconds(near, rec, sr)
me_ranges = [(s["start"], s["end"]) for s in segs if s["speaker"] == "me"]
clear = [s for s in segs if s["track"] == "remote" and all(s["end"] <= a or s["start"] >= b for a, b in me_ranges)]
rem = np.concatenate([window(rec, sr, s["start"], s["end"], off) for s in clear])
me = np.concatenate([window(rec, sr, s["start"], s["end"], off) for s in segs if s["placement"] == "gap"])
print(f"offset {off:.2f}s  remote stretches {db(rem):.1f} dBFS  me stretches {db(me):.1f} dBFS  margin {db(me) - db(rem):+.1f} dB")
pcm = ta.pcm16k(work / f"{name}.wav")
sf.write(work / f"{name}.16k.wav", pcm, 16000, subtype="PCM_16")
texts = {"vertex": ta.vertex_file(ta.wav_bytes(pcm))["text"], "whisper": ta.whisper(work / f"{name}.16k.wav")}
for eng, t in texts.items():
    gap = np.mean([recall(s["text"], t) for s in segs if s["placement"] == "gap"])
    ovl = np.mean([recall(s["text"], t) for s in segs if s["placement"] == "overlap"])
    rr = np.mean([recall(s["text"], t) for s in segs if s["track"] == "remote"])
    print(f"{eng:8s} me gaps {gap:.0f}  me double talk {ovl:.0f}  remote {rr:.0f}  | {t[:90]!r}")
