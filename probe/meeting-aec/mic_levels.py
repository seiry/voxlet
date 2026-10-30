"""Level distribution of a recorded meeting mic track in remote-only vs local-talker stretches, to tune the turn
segmenter. mic_levels.py <mic.m4a> <near.wav> <truth.json>"""

import json
import subprocess
import sys

import numpy as np
import soundfile as sf

from prep import offset_seconds

mic_path, near_path, truth_path = sys.argv[1:4]
wav = mic_path + ".wav"
subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", mic_path, "-ar", "48000", "-ac", "1", wav], check=True)
mic, sr = sf.read(wav, dtype="float32")
near, _ = sf.read(near_path, dtype="float32")
off = offset_seconds(near, mic, sr)
segs = json.load(open(truth_path))["segments"]
hop = int(sr * 0.1)


def chunks(start, end):
    a, b = int((start + off) * sr), int((end + off) * sr)
    x = mic[max(0, a):max(0, b)]
    n = len(x) // hop
    return [20 * np.log10(np.sqrt(np.mean(x[i * hop:(i + 1) * hop] ** 2)) + 1e-9) for i in range(n)]


me_ranges = [(s["start"], s["end"]) for s in segs if s["speaker"] == "me"]
remote_only = [c for s in segs if s["speaker"] != "me" and all(s["end"] <= a or s["start"] >= b for a, b in me_ranges)
               for c in chunks(s["start"], s["end"])]
me = [c for s in segs if s["speaker"] == "me" for c in chunks(s["start"], s["end"])]
print(f"offset {off:.2f}s")
for name, v in (("remote-only stretches", remote_only), ("my stretches", me)):
    v = np.array(v)
    print(f"{name:22s} n={len(v)} p50 {np.percentile(v, 50):6.1f} p90 {np.percentile(v, 90):6.1f} p99 {np.percentile(v, 99):6.1f} "
          f">-45: {np.mean(v > -45) * 100:4.1f}%  >-40: {np.mean(v > -40) * 100:4.1f}%")
# Runs of consecutive chunks above -45 inside remote-only stretches: what would open a false "me" turn.
runs, cur = [], 0
for c in remote_only:
    cur = cur + 1 if c > -45 else 0
    if cur == 0 and runs and runs[-1] != 0:
        runs.append(0)
    elif cur:
        runs.append(cur)
print("longest false run (chunks):", max(runs) if runs else 0)
