"""Runs every engine on every input and writes results/<input>.<engine>.json ({text, seconds, error}).
Engines: whisper.cpp large-v3-turbo (local), Vertex gemini-3.5-transcribe (file), Vertex
gemini-3.5-transcribe-live (WebSocket, streamed in real time), gemini-3.8-flash via the new-api gateway."""

import asyncio
import base64
import io
import json
import os
import pathlib
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import requests
import soundfile as sf
import websockets
from google import genai
from google.genai import types

import creds

INPUTS = ["remote", "near", "mix", "A_raw", "B_vpio", "C_hijack", "A_gated"]
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "ggml-large-v3-turbo.bin")
LIVE_URL = "wss://aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1.LlmBidiService/BidiGenerateContent"
C = creds.load()


def pcm16k(path: pathlib.Path) -> np.ndarray:
    x, sr = sf.read(path, dtype="float32", always_2d=True)
    x = x[:, 0]
    n = int(len(x) * 16000 / sr)
    y = np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x)
    return (np.clip(y, -1, 1) * 32767).astype(np.int16)


def wav_bytes(pcm: np.ndarray) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, pcm, 16000, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def whisper(path16: pathlib.Path) -> str:
    out = str(path16).removesuffix(".wav")
    subprocess.run(["whisper-cli", "-m", WHISPER_MODEL, "-f", str(path16), "-l", "auto", "-otxt", "-of", out,
                    "-np"], check=True, capture_output=True)
    return pathlib.Path(out + ".txt").read_text().strip()


def vertex_file(wav: bytes, diarize: bool = False) -> dict:
    client = genai.Client(vertexai=True, api_key=C["VERTEX_KEY"])
    cfg = types.AudioTranscriptionConfig(diarization=True, word_timestamp=True) if diarize else types.AudioTranscriptionConfig()
    resp = client.models.generate_content(
        model="gemini-3.5-transcribe",
        contents=[types.Part.from_bytes(data=wav, mime_type="audio/wav")],
        config=types.GenerateContentConfig(audio_transcription_config=cfg),
    )
    content = resp.candidates[0].content if resp.candidates else None
    parts = (content.parts or []) if content else []
    words = []
    for p in parts:
        t = p.audio_transcription
        if t and t.words:
            for w in t.words:
                words.append({"word": w.word, "speaker": t.speaker_label,
                              "start": float(str(w.start_offset).rstrip("s") or 0),
                              "end": float(str(w.end_offset).rstrip("s") or 0)})
    return {"text": "".join(p.text or "" for p in parts), "words": words}


def flash(wav: bytes) -> str:
    body = {"contents": [{"role": "user", "parts": [
        {"text": "Transcribe this meeting audio verbatim, every speaker, in the original languages. "
                 "Output only the transcript text, no speaker names or timestamps."},
        {"inlineData": {"mimeType": "audio/wav", "data": base64.b64encode(wav).decode()}}]}]}
    r = requests.post(f"{C['OPENAI_BASE_URL'].removesuffix('/v1')}/v1beta/models/gemini-3.8-flash:generateContent",
                      headers={"x-goog-api-key": C["OPENAI_API_KEY"]}, json=body, timeout=300)
    r.raise_for_status()
    data = r.json()
    if "candidates" not in data:
        raise RuntimeError(f"no candidates: {json.dumps(data, ensure_ascii=False)[:300]}")
    parts = data["candidates"][0]["content"]["parts"]
    return "".join(p.get("text", "") for p in parts if not p.get("thought"))


async def live(pcm: np.ndarray) -> str:
    model = f"projects/{C['VERTEX_PROJECT']}/locations/global/publishers/google/models/gemini-3.5-transcribe-live"
    finals: list[str] = []
    async with websockets.connect(f"{LIVE_URL}?key={C['VERTEX_KEY']}", max_size=None) as ws:
        await ws.send(json.dumps({"setup": {"model": model, "generationConfig": {"responseModalities": ["TEXT"]},
                                            "inputAudioTranscription": {"languageCodes": [], "mode": "VERBATIM"}}}))
        while "setupComplete" not in json.loads(await ws.recv()):
            pass

        async def reader():
            async for raw in ws:
                msg = json.loads(raw)
                sc = msg.get("serverContent", {})
                t = sc.get("inputTranscription", {}).get("text")
                if t:
                    finals.append(t)

        task = asyncio.create_task(reader())
        chunk = 1600  # 100 ms
        for i in range(0, len(pcm), chunk):
            data = base64.b64encode(pcm[i:i + chunk].tobytes()).decode()
            await ws.send(json.dumps({"realtimeInput": {"audio": {"data": data, "mimeType": "audio/pcm;rate=16000"}}}))
            await asyncio.sleep(0.1)
        await ws.send(json.dumps({"realtimeInput": {"audioStreamEnd": True}}))
        # No turnComplete follows audioStreamEnd; finish on idle instead.
        last = -1
        while len(finals) != last:
            last = len(finals)
            await asyncio.sleep(4)
        task.cancel()
    return "".join(finals)


def done(out: pathlib.Path, name: str, engine: str) -> bool:
    p = out / f"{name}.{engine}.json"
    return p.exists() and "error" not in json.loads(p.read_text())


def save(out: pathlib.Path, name: str, engine: str, fn) -> None:
    if done(out, name, engine):
        return
    t0 = time.time()
    rec = {"input": name, "engine": engine}
    try:
        r = fn()
        rec.update(r if isinstance(r, dict) else {"text": r})
    except Exception as e:  # noqa: BLE001
        rec["error"] = f"{type(e).__name__}: {e}"[:500]
    rec["seconds"] = round(time.time() - t0, 1)
    (out / f"{name}.{engine}.json").write_text(json.dumps(rec, ensure_ascii=False, indent=1))
    print(f"{name:9s} {engine:12s} {rec['seconds']:6.1f}s {rec.get('error') or rec.get('text', '')[:60]!r}", flush=True)


def main(work: pathlib.Path) -> None:
    out = work / "results"
    out.mkdir(exist_ok=True)
    pcms = {n: pcm16k(work / f"{n}.wav") for n in INPUTS}
    for n, p in pcms.items():
        sf.write(work / f"{n}.16k.wav", p, 16000, subtype="PCM_16")
    with ThreadPoolExecutor(8) as pool:
        jobs = []
        for n in INPUTS:
            wav = wav_bytes(pcms[n])
            jobs.append(pool.submit(save, out, n, "vertex", lambda w=wav: vertex_file(w)))
            jobs.append(pool.submit(save, out, n, "flash", lambda w=wav: flash(w)))
        for n in ("mix", "A_raw", "remote"):
            wav = wav_bytes(pcms[n])
            jobs.append(pool.submit(save, out, n, "vertex_diar", lambda w=wav: vertex_file(w, diarize=True)))
        live_job = pool.submit(lambda: asyncio.run(run_live(out, pcms)))
        for n in INPUTS:
            save(out, n, "whisper", lambda n=n: whisper(work / f"{n}.16k.wav"))
        for j in jobs + [live_job]:
            j.result()


async def run_live(out: pathlib.Path, pcms: dict) -> None:
    async def one(n):
        if done(out, n, "live"):
            return
        t0 = time.time()
        rec = {"input": n, "engine": "live"}
        try:
            rec["text"] = await live(pcms[n])
        except Exception as e:  # noqa: BLE001
            rec["error"] = f"{type(e).__name__}: {e}"[:500]
        rec["seconds"] = round(time.time() - t0, 1)
        (out / f"{n}.live.json").write_text(json.dumps(rec, ensure_ascii=False, indent=1))
        print(f"{n:9s} {'live':12s} {rec['seconds']:6.1f}s {rec.get('error') or rec.get('text', '')[:60]!r}", flush=True)

    await asyncio.gather(*(one(n) for n in INPUTS))


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]))
