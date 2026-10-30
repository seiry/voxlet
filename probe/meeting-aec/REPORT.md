# Meeting mode on laptop speakers: echo and transcription probe

Run unattended on 2026-10-30 on a 16-inch MacBook Pro (macOS 27.2), built-in speakers at volume 54, built-in
mic. Question: without headphones, how do we get a clean "me" track while the meeting plays from the speakers,
and which transcription engine to use?

## Setup

- **Corpus** (`make_corpus.py`): a 67 s Chinese/English meeting from macOS TTS. Two remote voices (Reed,
  Shelley) and the local talker (Tingting). Of the local talker's 5 sentences, 3 sit in gaps and 2 start
  1 s into a remote sentence (double talk). `results/truth.json` has the timeline.
- **The local talker is a speaker that is not the Mac's**: an HDMI monitor speaker next to the laptop
  (`--near-device`). So the "person" is never in any echo reference, as a real voice would not be.
- **Recordings** (`record_matrix.sh`, `aecprobe.swift`), 3 rounds each:
  - **A_raw**: no processing; the remote track is played by another app (`afplay`), like a browser. This is
    the "mic only" plan.
  - **B_vpio**: Apple voice processing (AUVoiceProcessingIO) on the mic, remote still played by another
    app. No hijack.
  - **C_hijack**: voice processing, with the remote track replayed by the unit itself, as a tap-and-replay
    hijack would do.
- **Derived**: `A_gated` is A_raw with every stretch where the remote track (what a tap of the browser
  gives) is active muted (`prep.py`).
- **Engines** (`transcribe_all.py`):
  - whisper.cpp large-v3-turbo (local).
  - Vertex `gemini-3.5-transcribe` (file).
  - Vertex `gemini-3.5-transcribe-live` (streamed in real time).
  - `gemini-3.8-flash` through the new-api gateway, prompted to transcribe.
  - The gateway token has no access to `gpt-transcribe`, `gpt-live-transcribe` or `gemini-3.5-transcribe`,
    so OpenAI's models were not tested.

Recall is the fuzzy match (0-100) of each truth sentence inside the transcript. About 20 is the noise
floor: the score a sentence gets when it is not in the audio at all.

## Results (mean of 3 rounds; full tables in `results/`)

| pipeline | engine | me, gaps | me, double talk | remote | CER |
| :- | :- | -: | -: | -: | -: |
| A_raw (mic only) | whisper | 100 | 20 (lost) | 69 | 41% |
| A_raw (mic only) | vertex | 92 | 20 (lost) | 61 | 44% |
| A_raw (mic only) | live | 53 | 17 | 33 | 76% |
| **B_vpio (no hijack)** | **vertex** | **100** | **96** | **20 (gone)** | **1%** |
| B_vpio (no hijack) | whisper | 100 | 96 | 20 | 2% |
| B_vpio (no hijack) | live | 100 | 73 | 20 | 9% |
| C_hijack | vertex | 94 (one round lost a sentence) | 96 | 20 | 4% |
| A_gated (offline me) | vertex | 100 | 17 (cut by design) | 19 | 0% |
| remote clean (tap) | whisper / vertex / live | | | 75 / 64 / 33 | 30 / 43 / 76% |

### Levels in the mic (dBFS), all 3 rounds

| recording | remote stretches | me stretches | me minus remote |
| :- | -: | -: | -: |
| A_raw | -31.3 | -35.8 | -4.5 dB |
| B_vpio | -53.3 | -24.5 | **+28.7 dB** (28.4 to 29.0) |
| C_hijack | -46.4 | -24.9 | +21.6 dB (21.2 to 21.8) |

### Other measurements

- **Not limited to the probe's own process tree**: B repeated with the remote `afplay` started by the shell
  (`b_external.sh`), so it is not a child of the probe, as a browser would not be. Results:
  - Remote stretches -52.9 dBFS, local talker -24.4 dBFS, so a +28.5 dB margin, the same as B.
  - Vertex returned exactly the 5 local sentences (gaps 100, double talk 100, remote 20).
- **Me/them labels from the tap reference** (mic-only plan): 8 of 8 non-overlapping sentences right in
  every round. Per 50 ms frame it is only 79%, because pauses inside a remote sentence read as room tail.
- **Offline diarization**, Vertex with diarization on, per round:
  - Remote clean track: 2 speakers found, purity 84%.
  - A_raw: 3 speakers found, purity 73%, 81% and 99%.
  - Digital mix: 3 labels but only 2 distinct speakers found, purity 81%.
- **Ducking**: with voice processing running, other apps play about **6 dB quieter**. Measured on the
  iPhone mic over Continuity as an independent meter: -40 dB to -46 dB, 3 interleaved rounds. Setting the
  ducking config to `min` does not remove it. Setting it again after init gave -38, -36 and -47, so it is
  not reliable either. The unit's own playback (the hijack path) is not ducked.
- **Voice processing affects every app's mic**: while it runs, a parallel `sox` capture in another
  process also lost the speaker audio. Meet in the browser and Voxlet dictation would get the processed
  mic during a meeting.
- **The AVAudioEngine path fails on this Mac**. `setVoiceProcessingEnabled` makes the input 9 channels,
  and the engine fails with -10875. A raw AUVoiceProcessingIO unit at 48 kHz mono works, as
  stephenturner/trailmix#4 found.

### Engine notes

- **Vertex `gemini-3.5-transcribe`** is the most accurate on clean speech (1% CER on the local talker).
  With diarization on, it returned Traditional Chinese.
- **whisper large-v3-turbo** is close on clean speech. On a silent tail it invented "请不吝点赞,订阅,转发,
  打赏支持明镜与点点栏目".
- **`gemini-3.5-transcribe-live`** is clearly weaker:
  - Remote clean recall was 33, against 64 to 75 for the others.
  - It dropped double-talk sentences after processing (56 to 73).
  - It once prefixed a Hindi word.
  - One session closed with 1011 "Insufficient model resources".
- **`gemini-3.8-flash` as ASR is unusable**:
  - Gemini's filter blocked 3 of 7 inputs in every round (`blockReason: OTHER`).
  - On voice-processed audio, it returned invented English or Japanese conversations in every round.

## Conclusions

1. **Use Apple voice processing on the mic, and do not hijack.** On built-in speakers it removes
   everything the Mac plays, from any app (including one unrelated to ours), and keeps a voice from
   elsewhere in the room. Compared with
   hijacking, it gives 7 dB more margin, never dropped a sentence, and needs no replay path, so Meet's own
   echo canceller is untouched. The costs:
   - The meeting plays about 6 dB quieter.
   - Other apps' mic input is processed while it runs.
2. **Still tap the browser.** Its clean track is the "them" side: best for remote text and for
   diarization (2 of 2 speakers). The processed mic is the "me" side. That gives me/them for free.
3. **If voice processing is off or misbehaves, the mic-only plan still works**:
   - Live: transcribe the raw mic and label sentences by the tap reference (8 of 8 right).
   - Offline: transcribe the tap for "them", and the raw mic with tap-active stretches muted for "me".
   - Your words spoken over a remote speaker are lost in this plan (recall 17 to 20).
4. **Engines**:
   - Live: `gemini-3.5-transcribe-live`, the only streaming one tested. Expect noticeably worse text than
     the offline pass.
   - Offline: Vertex `gemini-3.5-transcribe`, with diarization on the tap track only.
   - whisper is a usable local fallback, behind a VAD gate.
   - Do not use a chat model as ASR.

## Not covered

- A real Firefox/Meet call and a real human voice. The HDMI speaker stands in for the person.
- The remote TTS voices are low quality and mispronounce English, so absolute remote scores are
  pessimistic. Compare pipelines, not absolute numbers.
- Whether far participants hear any echo.
- External speakers, AirPods and headphones.
- A Core Audio tap of a real browser. Process taps were not exercised; the remote track itself stood in
  for the tap.
- OpenAI's transcription models: the gateway token has no access.
- What `kAUVoiceIOProperty_BypassVoiceProcessing` does here is unclear. With bypass on, the probe's own
  capture was also near silent, and that was not cross-checked on the iPhone mic.

## Reproduce

```sh
./build.sh
uv run python make_corpus.py <dir>
./record_matrix.sh <dir>        # needs HDMI_DEVICE (default TS3400-U2L); keep the display awake
uv run python prep.py <dir>
PROBE_CREDS=creds.env WHISPER_MODEL=ggml-large-v3-turbo.bin uv run python transcribe_all.py <dir>
uv run python evaluate.py <dir>
uv run python aggregate.py <dir>...
```

`creds.env` holds `VERTEX_KEY`, `VERTEX_PROJECT`, `OPENAI_API_KEY` and `OPENAI_BASE_URL`; it is
git-ignored. The probe embeds the bundle id `dev.seiry.voxlet.aecprobe` and never touches Voxlet's
preferences or keychain item.
