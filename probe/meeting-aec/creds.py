"""Loads credentials from $PROBE_CREDS (KEY=VALUE lines); never commit that file."""

import os
import pathlib


def load() -> dict[str, str]:
    path = pathlib.Path(os.environ.get("PROBE_CREDS", "creds.env"))
    out = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out
