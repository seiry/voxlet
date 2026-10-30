"""Loudness of the active part of each WAV: mean dBFS of the loudest 20% of 50 ms frames."""

import sys

import numpy as np
import soundfile as sf


def active_db(path: str) -> float:
    x, sr = sf.read(path, dtype="float32", always_2d=True)
    x = x[:, 0]
    hop = int(sr * 0.05)
    frames = x[: len(x) // hop * hop].reshape(-1, hop)
    e = np.sqrt(np.mean(frames**2, axis=1)) + 1e-9
    top = np.sort(e)[-max(1, len(e) // 5):]
    return float(20 * np.log10(np.mean(top)))


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(f"{p.split('/')[-1]:16s} {active_db(p):6.1f} dB")
