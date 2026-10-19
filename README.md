# Voxlet

A small macOS menu bar app for push-to-talk dictation with **Gemini 3.5 Transcribe Live**. Hold a shortcut,
speak, release, and the transcript is pasted into whatever app has focus.

It is a stripped-down take on [Voxt](https://github.com/sgl-project/sglang-omni/tree/main/Voxt): the same
settings window, recording overlay and hotkey rules, with everything else removed (no local models, no
dictionary, no LLM rewrite, no meeting mode). Gemini's `SMART` transcription mode does the cleanup.

## Features

- Gemini Live over WebSocket, via **Agent Platform (Vertex AI)** with an API key, or **Google AI Studio**.
- Global shortcut: modifier-only (`fn`, Right ⌘, …, left and right told apart) or a key chord, as
  **hold to talk** or **tap to toggle**. Esc cancels.
- Voxt-style floating card with a live waveform and the running transcript.
- Paste into the focused app, then restore the previous clipboard (or keep the result, if you prefer).
- **Usage and cost**: token counts from the server's `usageMetadata` for each dictation, totals for today,
  this month and all time, with editable prices.
- English and Simplified Chinese UI.

## Build and run

Requires macOS 14+ and Xcode (Swift 6 toolchain). No Xcode project; it is a SwiftPM target plus a script that
assembles the app bundle.

```sh
./scripts/build.sh
open dist/Voxlet.app
```

On first launch, grant **Microphone** and **Accessibility** in Settings → Permissions, then fill in
Settings → Model:

| Provider | What to enter |
|---|---|
| Agent Platform | API key, project ID (or number), location (`global` works) |
| AI Studio | Gemini API key (needs a positive prepaid balance) |

Press **Test** to open a session; on failure it shows the server's close code and reason verbatim.

The build is signed ad hoc (set `SIGN_IDENTITY` to use a real identity), so macOS treats every rebuild as a new
app. If a permission looks enabled in System Settings but Voxlet says otherwise, remove the old entry there and
grant it again.

Using `fn` as the shortcut: set System Settings → Keyboard → "Press 🌐 key to" to "Do Nothing", or macOS will
open the emoji picker or system dictation as well.

## Protocol notes

What the code relies on, verified against the live API on 2026-10-20:

- **Agent Platform** endpoint: `wss://aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1.LlmBidiService/BidiGenerateContent?key=…`.
  The model must be the full resource path
  `projects/<project>/locations/<location>/publishers/google/models/gemini-3.5-transcribe-live`;
  `models/…` and `publishers/…` are rejected with close code 1007, and so is a setup without
  `inputAudioTranscription`.
- `interimInputTranscription` carries the running text of the current turn; `inputTranscription` carries the
  turn's final text; `generationComplete` follows each turn. A pause starts a new turn.
- After `audioStreamEnd` the server sends no `turnComplete` and keeps the socket open, and an earlier turn
  can still complete after it. Voxlet therefore finishes 0.6 s after a turn completes or 1.5 s after the last
  transcript message, capped at 10 s.
- `usageMetadata` arrives once per turn (audio at 25 tokens per second), so a dictation's usage is the sum.

## Testing

```sh
VOXLET_API_KEY=… VOXLET_PROJECT=… ./scripts/e2e.sh
```

Streams a synthesized two-turn Chinese and English clip (44.1 kHz stereo, with a pause) through the packaged
binary's converter and Live session, checks the transcript, usage and finish timing, and renders every settings
page and overlay state to PNG. Output lands in `dist/e2e/`.

Two developer modes back it: `Voxlet --selftest <audio> [--out result.json]` (configured through `VOXLET_*`
environment variables) and `Voxlet --render-previews <dir>`.

## License

Apache-2.0. Portions are adapted from Voxt; see [NOTICE](NOTICE).
