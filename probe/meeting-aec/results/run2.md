# Results

## Sentence recall (0-100) and CER

| input | engine | me in gaps | me over remote | remote | CER vs expected | note |
| :- | :- | -: | -: | -: | -: | :- |
| remote clean (browser tap) | whisper | 25 | 20 | 75 | 30% | |
| remote clean (browser tap) | vertex | 24 | 20 | 64 | 43% | |
| remote clean (browser tap) | live | 22 | 20 | 33 | 76% | |
| remote clean (browser tap) | flash | | | | | error: RuntimeError: no candidates: {"promptFeedback": {"blockReason": "OTHER |
| near clean (local talker) | whisper | 95 | 100 | 20 | 16% | |
| near clean (local talker) | vertex | 100 | 96 | 20 | 1% | |
| near clean (local talker) | live | 100 | 100 | 20 | 0% | |
| near clean (local talker) | flash | 100 | 100 | 20 | 0% | |
| digital mix (headphones ideal) | whisper | 95 | 88 | 59 | 40% | |
| digital mix (headphones ideal) | vertex | 100 | 59 | 53 | 45% | |
| digital mix (headphones ideal) | live | 91 | 81 | 32 | 100% | |
| digital mix (headphones ideal) | flash | 100 | 96 | 78 | 21% | |
| A: raw mic, speakers (mic-only plan) | whisper | 100 | 20 | 69 | 38% | |
| A: raw mic, speakers (mic-only plan) | vertex | 77 | 20 | 59 | 49% | |
| A: raw mic, speakers (mic-only plan) | live | 38 | 14 | 28 | 86% | |
| A: raw mic, speakers (mic-only plan) | flash | | | | | error: RuntimeError: no candidates: {"promptFeedback": {"blockReason": "OTHER |
| B: voice processing, no hijack | whisper | 100 | 96 | 20 | 1% | |
| B: voice processing, no hijack | vertex | 100 | 96 | 20 | 1% | |
| B: voice processing, no hijack | live | 100 | 92 | 20 | 3% | |
| B: voice processing, no hijack | flash | 100 | 100 | 26 | 81% | |
| C: voice processing + hijack replay | whisper | 100 | 96 | 20 | 1% | |
| C: voice processing + hijack replay | vertex | 100 | 96 | 20 | 1% | |
| C: voice processing + hijack replay | live | 100 | 42 | 19 | 17% | |
| C: voice processing + hijack replay | flash | 100 | 100 | 25 | 79% | |
| A gated by tap reference (offline me) | whisper | 95 | 17 | 19 | 2% | |
| A gated by tap reference (offline me) | vertex | 100 | 17 | 19 | 0% | |
| A gated by tap reference (offline me) | live | 98 | 17 | 19 | 4% | |
| A gated by tap reference (offline me) | flash | 100 | 17 | 19 | 0% | |

Remote recall on `near clean` is the noise floor for leakage: no remote sentence is in that audio.

## Levels in the recordings (dBFS)

| recording | remote-only stretches | me-only stretches | me minus remote |
| :- | -: | -: | -: |
| A_raw | -31.3 | -35.9 | -4.6 dB |
| B_vpio | -53.5 | -24.6 | +28.8 dB |
| C_hijack | -46.4 | -24.7 | +21.8 dB |

## Me/them labels from the tap reference (mic-only plan)

- Per sentence (majority of active frames, overlapping sentences excluded): **8/8**.
- Per 50 ms frame on single-speaker frames: 78.8% (820/1041); pauses inside a remote sentence read as the room tail on the mic and drag this down.

## Offline diarization (Vertex gemini-3.5-transcribe, diarization on)

| input | labels returned | words scored | purity |
| :- | -: | -: | -: |
| remote | 2 (spk:0->R, spk:1->S) | 128 | 84% |
| mix | 3 (spk:0->me, spk:1->R, spk:3->me) | 48 | 81% |
| A_raw | 3 (spk:0->R, spk:1->me, spk:2->S) | 107 | 81% |
