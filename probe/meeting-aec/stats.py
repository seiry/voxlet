"""Prints duration, peak and RMS (dBFS) for each WAV given."""

import sys

import numpy as np
import soundfile as sf

for path in sys.argv[1:]:
    x, sr = sf.read(path, dtype="float32", always_2d=True)
    x = x[:, 0]
    rms = np.sqrt(np.mean(x**2)) if len(x) else 0.0
    print(f"{path.split('/')[-1]:24s} {len(x) / sr:5.1f}s peak {np.max(np.abs(x)):.3f} rms {20 * np.log10(rms + 1e-12):6.1f} dBFS")
