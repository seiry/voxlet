"""Does gemini-3.5-transcribe-live accept client-side turns? Streams the mixed meeting with automatic activity
detection off, opening and closing a turn whenever the speaking side changes (known from the two tracks), and
prints every server message kind per turn. manual_vad_test.py <corpus dir>"""

import asyncio
import base64
import json
import pathlib
import sys

import numpy as np
import soundfile as sf
import websockets

import creds

C = creds.load()
URL = "wss://aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1.LlmBidiService/BidiGenerateContent"


def load16(path):
    x, sr = sf.read(path, dtype="float32")
    n = int(len(x) * 16000 / sr)
    return np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x).astype(np.float32)


async def main(work: pathlib.Path):
    me, them = load16(work / "near.wav"), load16(work / "remote.wav")
    n = min(len(me), len(them))
    chunk = 1600
    model = f"projects/{C['VERTEX_PROJECT']}/locations/global/publishers/google/models/gemini-3.5-transcribe-live"
    events = []
    t0 = asyncio.get_event_loop().time()
    async with websockets.connect(f"{URL}?key={C['VERTEX_KEY']}", max_size=None) as ws:
        await ws.send(json.dumps({"setup": {
            "model": model, "generationConfig": {"responseModalities": ["TEXT"]},
            "realtimeInputConfig": {"automaticActivityDetection": {"disabled": True}},
            "inputAudioTranscription": {"languageCodes": [], "mode": "VERBATIM"}}}))
        first = json.loads(await ws.recv())
        print("setup reply:", list(first))

        async def reader():
            async for raw in ws:
                m = json.loads(raw)
                now = asyncio.get_event_loop().time() - t0
                sc = m.get("serverContent", {})
                kinds = [k for k in sc if k not in ("modelTurn",)] or list(m)
                text = sc.get("inputTranscription", {}).get("text") or sc.get("interimInputTranscription", {}).get("text")
                events.append((round(now, 1), kinds, text))
                if "inputTranscription" in sc:
                    print(f"{now:5.1f} FINAL {text}")

        task = asyncio.create_task(reader())
        side, quiet, active_run = None, 0, {"me": 0, "them": 0}
        for i in range(0, n - chunk, chunk):
            a, b = me[i:i + chunk], them[i:i + chunk]
            db = {k: 20 * np.log10(np.sqrt(np.mean(v ** 2)) + 1e-9) for k, v in (("me", a), ("them", b))}
            for k in db:
                active_run[k] = active_run[k] + 1 if db[k] > -45 else 0
            loud = [k for k in db if active_run[k] >= 2]
            t = i / 16000
            if side is None and loud:
                side = max(loud, key=lambda k: db[k])
                await ws.send(json.dumps({"realtimeInput": {"activityStart": {}}}))
                print(f"{t:5.1f} start {side}")
            elif side is not None:
                other = "them" if side == "me" else "me"
                quiet = quiet + 1 if db[side] <= -45 else 0
                if quiet >= 5 or (quiet >= 2 and active_run[other] >= 3):
                    await ws.send(json.dumps({"realtimeInput": {"activityEnd": {}}}))
                    print(f"{t:5.1f} end   {side}")
                    side, quiet = None, 0
                    if active_run[other] >= 3:
                        side = other
                        await ws.send(json.dumps({"realtimeInput": {"activityStart": {}}}))
                        print(f"{t:5.1f} start {side}")
            mixed = np.clip(a + b, -1, 1)
            pcm = (mixed * 32767).astype(np.int16).tobytes()
            await ws.send(json.dumps({"realtimeInput": {"audio": {"data": base64.b64encode(pcm).decode(), "mimeType": "audio/pcm;rate=16000"}}}))
            await asyncio.sleep(0.1)
        if side is not None:
            await ws.send(json.dumps({"realtimeInput": {"activityEnd": {}}}))
        await asyncio.sleep(6)
        task.cancel()
    kinds = {}
    for _, k, _ in events:
        for x in k:
            kinds[x] = kinds.get(x, 0) + 1
    print("message kinds:", kinds)


asyncio.run(main(pathlib.Path(sys.argv[1])))
