"""Transcribes each WAV with Vertex gemini-3.5-transcribe (16 kHz mono) and prints the text."""

import io
import sys

import numpy as np
import soundfile as sf
from google import genai
from google.genai import types

import creds


def to16k(path: str) -> bytes:
    x, sr = sf.read(path, dtype="float32", always_2d=True)
    x = x[:, 0]
    n = int(len(x) * 16000 / sr)
    y = np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x).astype(np.float32)
    buf = io.BytesIO()
    sf.write(buf, y, 16000, format="WAV", subtype="PCM_16")
    return buf.getvalue()


client = genai.Client(vertexai=True, api_key=creds.load()["VERTEX_KEY"])
for path in sys.argv[1:]:
    resp = client.models.generate_content(
        model="gemini-3.5-transcribe",
        contents=[types.Part.from_bytes(data=to16k(path), mime_type="audio/wav")],
        config=types.GenerateContentConfig(audio_transcription_config=types.AudioTranscriptionConfig()),
    )
    content = resp.candidates[0].content if resp.candidates else None
    text = "".join(p.text or "" for p in (content.parts or [])) if content else ""
    print(f"{path.split('/')[-1]}: {text!r}")
