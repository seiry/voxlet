"""Builds the meeting corpus with macOS TTS: remote.wav (two remote voices), near.wav (the local talker),
mix.wav (their digital sum, the headphones ideal) and truth.json. All 48 kHz mono float."""

import json
import pathlib
import subprocess
import sys

import numpy as np
import soundfile as sf

RATE = 48_000
VOICES = {"R": "Reed (中文（中国大陆）)", "S": "Shelley (中文（中国大陆）)", "me": "Tingting"}

# (speaker, text, placement). Near-end lines go in the gap after the previous line, or start 1 s into it.
SCRIPT = [
    ("R", "大家好，今天我们过一下 Voxlet 会议模式的进度，先说说上周的 release。", None),
    ("S", "上周发了零点三版本，主要修了 hotkey 的问题，crash rate 已经降到百分之一以下。", None),
    ("me", "我补充一下，耳机模式我已经测过了，没有问题。", "gap"),
    ("R", "好的。那 Gemini Live 的十分钟限制，现在是怎么处理的？", None),
    ("S", "我们会在第九分钟提前建一个新的 WebSocket 连接，两边重叠两秒，再做去重。", None),
    ("me", "对，这个方案我同意。", "overlap"),
    ("R", "回声消除这块，Recall 用的是 WebRTC AEC3，我们要不要也试一下？", None),
    ("me", "我觉得先测 Apple 的 voice processing，不行再换。", "gap"),
    ("S", "可以，不过要先确认它会不会把对方的声音压低，周五之前给结论。", None),
    ("me", "预算控制在每小时一美元以内。", "overlap"),
    ("R", "那 action item 就是周五前出一份 echo cancellation 的测试报告，Seiry 负责。", None),
    ("me", "没问题，我来跟进。", "gap"),
]
GAP = 0.8
LEAD = 0.5


def tts(voice: str, text: str, work: pathlib.Path, i: int) -> np.ndarray:
    aiff = work / f"seg{i:02d}.aiff"
    wav = work / f"seg{i:02d}.wav"
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(aiff), "-ar", str(RATE), "-ac", "1",
                    "-c:a", "pcm_f32le", str(wav)], check=True)
    x, _ = sf.read(wav, dtype="float32")
    return x


def main(out: pathlib.Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    tmp = out / "segs"
    tmp.mkdir(exist_ok=True)
    audio = [tts(VOICES[spk], text, tmp, i) for i, (spk, text, _) in enumerate(SCRIPT)]
    segs = []
    cursor = LEAD
    prev_remote = None
    for (spk, text, place), x in zip(SCRIPT, audio):
        dur = len(x) / RATE
        if spk == "me" and place == "overlap":
            start = prev_remote["start"] + 1.0
        else:
            start = cursor
        segs.append({"speaker": spk, "track": "near" if spk == "me" else "remote", "text": text,
                     "start": round(start, 3), "end": round(start + dur, 3), "placement": place})
        if spk != "me":
            prev_remote = segs[-1]
        cursor = max(cursor, start + dur + GAP)
    total = cursor + 1.0
    n = int(total * RATE)
    remote = np.zeros(n, np.float32)
    near = np.zeros(n, np.float32)
    for seg, x in zip(segs, audio):
        i = int(seg["start"] * RATE)
        (near if seg["track"] == "near" else remote)[i:i + len(x)] += x
    sf.write(out / "remote.wav", remote, RATE, subtype="FLOAT")
    sf.write(out / "near.wav", near, RATE, subtype="FLOAT")
    sf.write(out / "mix.wav", np.clip(remote + near, -1, 1), RATE, subtype="FLOAT")
    (out / "truth.json").write_text(json.dumps({"duration": total, "segments": segs}, ensure_ascii=False, indent=1))
    print(f"corpus: {total:.1f}s, {len(segs)} segments -> {out}")


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]))
