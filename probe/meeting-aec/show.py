"""Prints the near-end truth and the named result transcripts: show.py <work> <input.engine>..."""

import json
import pathlib
import sys

work = pathlib.Path(sys.argv[1])
for s in json.loads((work / "truth.json").read_text())["segments"]:
    if s["speaker"] == "me":
        print(f"truth {s['placement']:8s} {s['start']:5.1f}s {s['text']}")
for key in sys.argv[2:]:
    r = json.loads((work / "results" / f"{key}.json").read_text())
    print(f"== {key}\n{r.get('text') or r.get('error')}")
