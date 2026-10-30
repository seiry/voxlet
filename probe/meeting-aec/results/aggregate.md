Runs: 3

| input.engine | me in gaps (mean / worst) | me over remote | remote | CER mean |
| :- | -: | -: | -: | -: |
| A_gated.flash (3) | 100 / 100 | 17 / 17 | 19 | 0% |
| A_gated.live (3) | 95 / 90 | 17 / 17 | 19 | 8% |
| A_gated.vertex (3) | 100 / 100 | 17 / 17 | 19 | 0% |
| A_gated.whisper (3) | 90 / 80 | 17 / 17 | 17 | 11% |
| A_raw.live (3) | 53 / 38 | 17 / 14 | 33 | 76% |
| A_raw.vertex (3) | 92 / 77 | 20 / 20 | 61 | 44% |
| A_raw.whisper (3) | 100 / 100 | 20 / 20 | 69 | 41% |
| B_vpio.flash (3) | 100 / 100 | 97 / 96 | 24 | 78% |
| B_vpio.live (3) | 100 / 100 | 73 / 46 | 20 | 9% |
| B_vpio.vertex (3) | 100 / 100 | 96 / 96 | 20 | 1% |
| B_vpio.whisper (3) | 100 / 100 | 96 / 92 | 20 | 2% |
| C_hijack.flash (3) | 94 / 81 | 99 / 96 | 24 | 72% |
| C_hijack.live (3) | 94 / 81 | 56 / 42 | 20 | 17% |
| C_hijack.vertex (3) | 94 / 81 | 96 / 96 | 20 | 4% |
| C_hijack.whisper (3) | 92 / 81 | 96 / 92 | 20 | 9% |
| mix.flash (1) | 100 / 100 | 96 / 96 | 78 | 21% |
| mix.live (3) | 91 / 91 | 81 / 81 | 32 | 100% |
| mix.vertex (3) | 100 / 100 | 59 / 59 | 53 | 45% |
| mix.whisper (3) | 95 / 95 | 88 / 88 | 59 | 40% |
| near.flash (3) | 100 / 100 | 99 / 96 | 20 | 0% |
| near.live (3) | 100 / 100 | 100 / 100 | 20 | 0% |
| near.vertex (3) | 100 / 100 | 96 / 96 | 20 | 1% |
| near.whisper (3) | 95 / 95 | 100 / 100 | 20 | 16% |
| remote.live (3) | 22 / 22 | 20 / 20 | 33 | 76% |
| remote.vertex (3) | 24 / 24 | 20 / 20 | 64 | 43% |
| remote.whisper (3) | 25 / 25 | 20 / 20 | 75 | 30% |

- diar.A_raw: labels [3, 3, 3], speakers_found [3, 3, 3], purity [73.3, 81.3, 99.2]
- diar.mix: labels [3, 3, 3], speakers_found [2, 2, 2], purity [81.2, 81.2, 81.2]
- diar.remote: labels [2, 2, 2], speakers_found [2, 2, 2], purity [83.6, 83.6, 83.6]
- labels: sentences_ok [8, 8, 8], sentences [8, 8, 8], frame_pct [78.9, 78.8, 79.1]
- level.A_raw: remote [-31.3, -31.3, -31.3], me [-35.7, -35.9, -35.9], margin [-4.4, -4.6, -4.6]
- level.B_vpio: remote [-52.8, -53.5, -53.6], me [-24.4, -24.6, -24.6], margin [28.4, 28.8, 29.0]
- level.C_hijack: remote [-46.5, -46.4, -46.4], me [-25.3, -24.7, -24.6], margin [21.2, 21.8, 21.8]
