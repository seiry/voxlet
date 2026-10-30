#!/bin/zsh
# Builds the probe CLI with an embedded Info.plist (test bundle id, never Voxlet's).
set -eu
cd "${0:A:h}"
mkdir -p build
swiftc -O -swift-version 5 aecprobe.swift -o build/aecprobe \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
