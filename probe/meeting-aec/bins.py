"""1 s level bins (dBFS) of WAVs between two times: bins.py <from> <to> <wav>..."""

import sys

import numpy as np
import soundfile as sf

a, b = float(sys.argv[1]), float(sys.argv[2])
for p in sys.argv[3:]:
    x, sr = sf.read(p, dtype="float32")
    row = []
    for t in np.arange(a, b, 1.0):
        w = x[int(t * sr):int((t + 1) * sr)]
        row.append(f"{20 * np.log10(np.sqrt(np.mean(w**2)) + 1e-9):6.0f}" if len(w) else "   end")
    print(f"{p.split('/')[-1]:14s}" + "".join(row))
print(" " * 14 + "".join(f"{t:6.0f}" for t in np.arange(a, b, 1.0)))
