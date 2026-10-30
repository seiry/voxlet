"""Aligns the raw mic recording to the remote track and derives A_gated: the raw mic with every stretch
where the remote track (what a tap of the browser gives) is active muted, leaving only the local talker."""

import json
import pathlib
import sys

import numpy as np
import soundfile as sf

HOP = 0.01


def envelope(x: np.ndarray, sr: int) -> np.ndarray:
    h = int(sr * HOP)
    f = x[: len(x) // h * h].reshape(-1, h)
    return np.sqrt(np.mean(f**2, axis=1))


def offset_seconds(ref: np.ndarray, rec: np.ndarray, sr: int) -> float:
    """Delay of ref inside rec, by cross-correlating 10 ms envelopes."""
    a, b = envelope(ref, sr), envelope(rec, sr)
    a, b = a - a.mean(), b - b.mean()
    corr = np.correlate(b, a, mode="full")
    lag = int(np.argmax(corr)) - (len(a) - 1)
    return lag * HOP


def active_mask(x: np.ndarray, sr: int, pad: float = 0.3) -> np.ndarray:
    e = envelope(x, sr)
    on = 20 * np.log10(e + 1e-9) > -50
    k = int(pad / HOP)
    return np.convolve(on.astype(float), np.ones(2 * k + 1), mode="same") > 0


def main(work: pathlib.Path) -> None:
    remote, sr = sf.read(work / "remote.wav", dtype="float32")
    near, _ = sf.read(work / "near.wav", dtype="float32")
    align = {}
    for name in ("A_raw", "B_vpio", "C_hijack"):
        rec, _ = sf.read(work / f"{name}.wav", dtype="float32")
        ref = near if name != "A_raw" else remote
        align[name] = round(offset_seconds(ref, rec, sr), 3)
    rec, _ = sf.read(work / "A_raw.wav", dtype="float32")
    off = align["A_raw"]
    mask = active_mask(remote, sr)
    h = int(sr * HOP)
    gated = rec.copy()
    for i, on in enumerate(mask):
        if on:
            s = int((i * HOP + off) * sr)
            gated[max(0, s):max(0, s + h)] = 0
    sf.write(work / "A_gated.wav", gated, sr, subtype="FLOAT")
    (work / "align.json").write_text(json.dumps(align, indent=1))
    print("align (s):", align)


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]))
