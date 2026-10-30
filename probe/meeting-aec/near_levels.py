"""Level of each local-talker sentence in each recording (dBFS), aligned with align.json."""

import json
import pathlib
import sys

import numpy as np
import soundfile as sf

work = pathlib.Path(sys.argv[1])
segs = [s for s in json.loads((work / "truth.json").read_text())["segments"] if s["speaker"] == "me"]
align = json.loads((work / "align.json").read_text())
print("sentence" + "".join(f"{n:>11s}" for n in align))
for s in segs:
    row = f"{s['start']:5.1f}s {s['placement']:8s}"
    for name, off in align.items():
        x, sr = sf.read(work / f"{name}.wav", dtype="float32")
        w = x[int((s["start"] + off) * sr):int((s["end"] + off) * sr)]
        row += f"{20 * np.log10(np.sqrt(np.mean(w**2)) + 1e-9):11.1f}" if len(w) else f"{'(cut)':>11s}"
    print(row, s["text"][:16])
for name in align:
    x, sr = sf.read(work / f"{name}.wav", dtype="float32")
    print(f"{name}: {len(x) / sr:.1f}s recorded, offset {align[name]}s")
