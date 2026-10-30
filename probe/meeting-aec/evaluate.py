"""Scores results/*.json against truth.json and writes results/summary.md.

Recall per sentence is rapidfuzz partial_ratio of the sentence inside the transcript (0-100), on text
normalised to Simplified Chinese, lowercase, no punctuation or spaces. For B_vpio, C_hijack and A_gated the
remote recall is leakage; the near-only transcript gives its noise floor (sentences that were never there)."""

import json
import pathlib
import re
import sys

import numpy as np
import soundfile as sf
import zhconv
from rapidfuzz import fuzz
from rapidfuzz.distance import Levenshtein

ENGINES = ["whisper", "vertex", "live", "flash"]
INPUTS = {
    "remote": ("remote clean (browser tap)", {"R", "S"}),
    "near": ("near clean (local talker)", {"me"}),
    "mix": ("digital mix (headphones ideal)", {"R", "S", "me"}),
    "A_raw": ("A: raw mic, speakers (mic-only plan)", {"R", "S", "me"}),
    "B_vpio": ("B: voice processing, no hijack", {"me"}),
    "C_hijack": ("C: voice processing + hijack replay", {"me"}),
    "A_gated": ("A gated by tap reference (offline me)", {"me"}),
}


def norm(s: str) -> str:
    s = zhconv.convert(s, "zh-cn").lower()
    return re.sub(r"[\W_]+", "", s)


def recall(seg_text: str, transcript: str) -> float:
    a, b = norm(seg_text), norm(transcript)
    return fuzz.partial_ratio(a, b) if a and b else 0.0


def db(x: np.ndarray) -> float:
    return float(20 * np.log10(np.sqrt(np.mean(x**2)) + 1e-9)) if len(x) else float("nan")


def window(x, sr, start, end, off):
    return x[max(0, int((start + off) * sr)):max(0, int((end + off) * sr))]


def main(work: pathlib.Path) -> None:
    truth = json.loads((work / "truth.json").read_text())
    segs = truth["segments"]
    align = json.loads((work / "align.json").read_text())
    res = {}
    for p in (work / "results").glob("*.*.json"):
        r = json.loads(p.read_text())
        res[(r["input"], r["engine"])] = r
    lines = ["# Results", ""]
    extra = {}

    lines += ["## Sentence recall (0-100) and CER", "",
              "| input | engine | me in gaps | me over remote | remote | CER vs expected | note |",
              "| :- | :- | -: | -: | -: | -: | :- |"]
    table = {}
    for inp, (label, want) in INPUTS.items():
        expected = "".join(s["text"] for s in sorted(segs, key=lambda s: s["start"]) if s["speaker"] in want)
        if inp == "A_gated":
            expected = "".join(s["text"] for s in segs if s["speaker"] == "me" and s["placement"] == "gap")
        for eng in ENGINES:
            r = res.get((inp, eng))
            if not r:
                continue
            if "error" in r:
                lines.append(f"| {label} | {eng} | | | | | error: {r['error'][:70]} |")
                continue
            t = r.get("text", "")
            gap = np.mean([recall(s["text"], t) for s in segs if s["placement"] == "gap"])
            ovl = np.mean([recall(s["text"], t) for s in segs if s["placement"] == "overlap"])
            rem = np.mean([recall(s["text"], t) for s in segs if s["track"] == "remote"])
            cer = Levenshtein.normalized_distance(norm(expected), norm(t)) * 100
            table[(inp, eng)] = dict(gap=gap, overlap=ovl, remote=rem, cer=cer)
            lines.append(f"| {label} | {eng} | {gap:.0f} | {ovl:.0f} | {rem:.0f} | {cer:.0f}% | |")
    lines += ["", "Remote recall on `near clean` is the noise floor for leakage: no remote sentence is in that audio.", ""]

    sr = 48_000
    lines += ["## Levels in the recordings (dBFS)", "",
              "| recording | remote-only stretches | me-only stretches | me minus remote |", "| :- | -: | -: | -: |"]
    me_ranges = [(s["start"], s["end"]) for s in segs if s["speaker"] == "me"]
    def overlaps(s):
        return any(not (s["end"] <= a or s["start"] >= b) for a, b in me_ranges)
    for name in ("A_raw", "B_vpio", "C_hijack"):
        x, sr = sf.read(work / f"{name}.wav", dtype="float32")
        off = align[name]
        rem = np.concatenate([window(x, sr, s["start"], s["end"], off) for s in segs
                              if s["track"] == "remote" and not overlaps(s)])
        me = np.concatenate([window(x, sr, s["start"], s["end"], off) for s in segs
                             if s["speaker"] == "me" and s["placement"] == "gap"])
        lines.append(f"| {name} | {db(rem):.1f} | {db(me):.1f} | {db(me) - db(rem):+.1f} dB |")
        extra[f"level.{name}"] = {"remote": db(rem), "me": db(me), "margin": db(me) - db(rem)}
    lines.append("")

    # Me/them labelling for the mic-only plan: tap reference active -> them, else mic active -> me.
    hop = 0.05
    ref, _ = sf.read(work / "remote.wav", dtype="float32")
    mic, _ = sf.read(work / "A_raw.wav", dtype="float32")
    off = align["A_raw"]
    n = int(truth["duration"] / hop)
    correct = total = 0
    for i in range(n):
        t0 = i * hop
        r_on = db(ref[int(t0 * sr):int((t0 + hop) * sr)]) > -50
        m_on = db(window(mic, sr, t0, t0 + hop, off)) > -48
        truth_spk = {s["track"] for s in segs if s["start"] <= t0 + hop / 2 < s["end"]}
        if len(truth_spk) != 1:
            continue
        pred = "remote" if r_on else ("near" if m_on else None)
        total += 1
        correct += pred == next(iter(truth_spk))
    # Per sentence: the label is the majority vote of its active frames, as a transcript segment would get.
    seg_ok = seg_n = 0
    for s in segs:
        if any(o is not s and not (o["end"] <= s["start"] or o["start"] >= s["end"]) for o in segs):
            continue
        votes = []
        for t0 in np.arange(s["start"], s["end"], hop):
            r_on = db(ref[int(t0 * sr):int((t0 + hop) * sr)]) > -50
            m_on = db(window(mic, sr, t0, t0 + hop, off)) > -48
            if r_on or m_on:
                votes.append("remote" if r_on else "near")
        if votes:
            seg_n += 1
            seg_ok += max(set(votes), key=votes.count) == s["track"]
    extra["labels"] = {"sentences_ok": seg_ok, "sentences": seg_n, "frame_pct": 100 * correct / max(total, 1)}
    lines += ["## Me/them labels from the tap reference (mic-only plan)", "",
              f"- Per sentence (majority of active frames, overlapping sentences excluded): **{seg_ok}/{seg_n}**.",
              f"- Per 50 ms frame on single-speaker frames: {100 * correct / max(total, 1):.1f}% ({correct}/{total});"
              " pauses inside a remote sentence read as the room tail on the mic and drag this down.", ""]

    lines += ["## Offline diarization (Vertex gemini-3.5-transcribe, diarization on)", "",
              "| input | labels returned | words scored | purity |", "| :- | -: | -: | -: |"]
    for inp, off in (("remote", 0.0), ("mix", 0.0), ("A_raw", align["A_raw"] - 1.0)):
        r = res.get((inp, "vertex_diar"))
        if not r or "error" in r or not r.get("words"):
            lines.append(f"| {inp} | | | {r.get('error', 'no words') if r else 'missing'} |")
            continue
        pairs = []
        for w in r["words"]:
            mid = (w["start"] + w["end"]) / 2 - off
            spk = [s["speaker"] for s in segs if s["start"] <= mid < s["end"]]
            if len(spk) == 1:
                pairs.append((w["speaker"], spk[0]))
        labels = sorted({p[0] for p in pairs})
        mapping = {}
        for lab in labels:
            votes = [t for l, t in pairs if l == lab]
            mapping[lab] = max(set(votes), key=votes.count)
        purity = 100 * sum(mapping[l] == t for l, t in pairs) / max(len(pairs), 1)
        extra[f"diar.{inp}"] = {"labels": len(labels), "speakers_found": len(set(mapping.values())), "purity": purity}
        lines.append(f"| {inp} | {len(labels)} ({', '.join(f'{l}->{mapping[l]}' for l in labels)}) | {len(pairs)} | {purity:.0f}% |")
    lines.append("")

    (work / "results" / "summary.md").write_text("\n".join(lines))
    scores = {f"{k[0]}.{k[1]}": v for k, v in table.items()}
    scores.update(extra)
    (work / "results" / "scores.json").write_text(json.dumps(scores, indent=1))
    print("\n".join(lines))


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]))
