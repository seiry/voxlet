"""Mean (and worst) of each metric across runs: aggregate.py <run dir>... ; prints markdown."""

import json
import pathlib
import sys

import numpy as np

runs = [json.loads((pathlib.Path(d) / "results" / "scores.json").read_text()) for d in sys.argv[1:]]
keys = sorted(set().union(*runs))
print(f"Runs: {len(runs)}\n")
print("| input.engine | me in gaps (mean / worst) | me over remote | remote | CER mean |")
print("| :- | -: | -: | -: | -: |")
for k in keys:
    vals = [r[k] for r in runs if k in r]
    if not vals or "gap" not in vals[0]:
        continue
    g = [v["gap"] for v in vals]
    o = [v["overlap"] for v in vals]
    rm = [v["remote"] for v in vals]
    c = [v["cer"] for v in vals]
    print(f"| {k} ({len(vals)}) | {np.mean(g):.0f} / {min(g):.0f} | {np.mean(o):.0f} / {min(o):.0f} | {np.mean(rm):.0f} | {np.mean(c):.0f}% |")
print()
for k in keys:
    vals = [r[k] for r in runs if k in r]
    if vals and "gap" not in vals[0]:
        merged = {f: [v[f] for v in vals] for f in vals[0]}
        print(f"- {k}: " + ", ".join(f"{f} {np.round(v, 1).tolist()}" for f, v in merged.items()))
