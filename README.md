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
- **Vocabulary**: names and jargon sent to Gemini as `customVocabulary`, kept in
  `~/.config/voxlet/vocabulary.txt` (plain text, one term per line, `#` for comments) and editable in Settings or
  any editor. Select a word anywhere and press the dictation shortcut to add it instead of dictating, as in Voxt
  (at most 5 words and 10 CJK characters in a row; a longer selection is dictated over).
- **Usage and cost**: token counts from the server's `usageMetadata` for each dictation, totals for today,
  this month and all time, with editable prices.
- **Meeting notes** (macOS 26+): start from the menu bar during a call. Voxlet records your microphone and what the
  browser plays, transcribes both live as "me" and "them" in a floating panel that stays out of screen sharing
  and remembers which display it was on, keeps running notes, and answers questions about the meeting so far.
  Afterwards both tracks are transcribed again offline with speakers told apart, and the meeting lands in
  `~/Meetings/<date time title>/` as `notes.md`, `transcript.md`, `meeting.json` and `audio/`.
- English and Simplified Chinese UI.

## Meeting mode

- **No headphones needed.** On speakers the microphone runs Apple's voice processing, which on a MacBook removes
  everything the speakers play, from any app, and keeps your voice. While it runs other apps play about 6 dB
  quieter. With headphones it stays off. Measurements are in `probe/meeting-aec/REPORT.md`.
- **One Live stream, turns cut locally.** Both sides are mixed into one Gemini Live session with automatic
  activity detection off; Voxlet opens and closes each turn when the speaking side changes, so every final has a
  side. Turns go out one at a time (the next waits for the last one's `generationComplete`), since Gemini merges
  turns that overlap on its side. A session is replaced in a quiet gap before its 10-minute limit.
- **Offline pass.** `gemini-3.5-transcribe` on Agent Platform, the microphone track as you and the browser track
  with diarization, then the notes model names the speakers and writes the notes.
- **Notes model.** Any Gemini-compatible `generateContent` endpoint (Settings → Meeting), for example a new-api
  gateway with `gemini-3.8-flash`. It only ever sees text.
- **Permissions.** Microphone, plus System Audio Recording, which macOS asks for the first time a meeting starts.

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

### Signing

macOS keys privacy grants (Microphone, Accessibility) and Keychain access to the app's designated requirement.
An ad hoc signature changes on every build, so every rebuild would need the permissions granted again. Run once:

```sh
./scripts/make-signing-cert.sh   # self-signed "Voxlet Local Signing" in its own keychain
./scripts/install.sh             # build, sign with it, copy to /Applications
```

`build.sh` signs with that identity whenever it exists (or with `SIGN_IDENTITY`), giving the requirement
`identifier "dev.seiry.voxlet" and certificate leaf = H"…"`, which stays the same across rebuilds. The
certificate is self-signed and untrusted, which is fine for local use; it is not meant for distribution. The
keychain lives at `~/Library/Keychains/voxlet-signing.keychain-db`, its password in `~/.config/voxlet-signing/`.

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

```sh
VOXLET_API_KEY=… VOXLET_PROJECT=… VOXLET_GATEWAY_KEY=… ./scripts/meeting-e2e.sh
VOXLET_API_KEY=… VOXLET_PROJECT=… VOXLET_GATEWAY_KEY=… ./scripts/meeting-device-check.sh
```

`meeting-e2e.sh` runs a 68 s, three-voice, Chinese and English meeting (two of the five local sentences spoken
over the other side) from two files through the whole meeting pipeline, with the Live session forced to roll
over every 25 s, and checks coverage, me/them labels, rollover, running notes, offline speakers, the to-do owner
and the files. `meeting-device-check.sh` does the same on real devices: QuickTime Player plays the other side
out of the Mac speakers, a second speaker (`HDMI_DEVICE`) plays you, and the packaged app records with voice
processing and the browser tap. `scripts/tap-check.sh` checks the tap alone.

## License

Apache-2.0. Portions are adapted from Voxt; see [NOTICE](NOTICE).
