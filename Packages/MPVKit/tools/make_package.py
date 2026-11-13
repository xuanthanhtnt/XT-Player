#!/usr/bin/env python3
"""Writes Packages/MPVKit/Package.swift: MPVKit's LGPL package with the FFmpeg libraries and libmpv replaced by
XT-Player's own build (published as assets of a GitHub release of this repository).

Usage: make_package.py <MPVKit Package.swift (upstream, or this one)> <dir with Lib*.xcframework.zip> <release tag> [--local]
  --local  point at Packages/MPVKit/local/<name>.xcframework instead (testing before the release exists;
           local/ is not committed).
"""
import re
import subprocess
import sys
from pathlib import Path

FFMPEG = ["Libavcodec", "Libavdevice", "Libavfilter", "Libavformat", "Libavutil", "Libswresample", "Libswscale"]
OWN = FFMPEG + ["Libmpv"]
REPO = "https://github.com/xuanthanhtnt/XT-Player/releases/download"

upstream, zips, tag = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
local = "--local" in sys.argv[4:]
source = upstream.read_text()

# Keep the LGPL product only.
source = source.replace('''        .library(
            name: "MPVKit-GPL",
            targets: ["_MPVKit-GPL"]
        ),
''', "")
source = re.sub(r'        \.target\(\n            name: "_MPVKit-GPL",.*?\n        \),\n', "", source, flags=re.S)
source = re.sub(r'        \.target\(\n            name: "_FFmpeg-GPL",.*?\n        \),\n', "", source, flags=re.S)
source = re.sub(r'        \.binaryTarget\(\n            name: "[A-Za-z0-9_]+-GPL",.*?\n        \),\n', "", source, flags=re.S)
source = re.sub(r'        \.binaryTarget\(\n            name: "Libsmbclient",.*?\n        \),\n', "", source, flags=re.S)

for name in OWN:
    if local:
        pattern = re.compile(r'\.binaryTarget\(\n            name: "%s",\n            (?:url: "[^"]+",\n            checksum: "[0-9a-f]+"|path: "[^"]+")\n        \)' % name)
        source, count = pattern.subn('.binaryTarget(\n            name: "%s",\n            path: "local/%s.xcframework"\n        )' % (name, name), source)
        assert count == 1, name
        continue
    archive = zips / f"{name}.xcframework.zip"
    checksum = subprocess.run(["swift", "package", "compute-checksum", str(archive)], capture_output=True, text=True, check=True).stdout.strip()
    pattern = re.compile(r'\.binaryTarget\(\n            name: "%s",\n            (?:url: "[^"]+",\n            checksum: "[0-9a-f]+"|path: "[^"]+")\n        \)' % name)
    target = '.binaryTarget(\n            name: "%s",\n            url: "%s/%s/%s.xcframework.zip",\n            checksum: "%s"\n        )' % (name, REPO, tag, name, checksum)
    source, count = pattern.subn(lambda _: target, source)
    assert count == 1, name

header = (
    "// XT-Player: MPVKit 1.1.0-n9.0.2 with FFmpeg rebuilt by ffmpeg-build.patch (DSD, WavPack, MLP, raw DTS / TrueHD,\n"
    "// S/PDIF bitstreaming, VVC, loudness and dialogue filters) and libmpv 0.41 rebuilt with mpv-build.patch\n"
    "// (CoreAudio hotplug fix). Regenerate with tools/make_package.py.\n"
)
source = re.sub(r"\A(// swift-tools-version:5\.9\n)(// .*\n)*", r"\1", source)
Path(__file__).resolve().parent.parent.joinpath("Package.swift").write_text(source.replace("// swift-tools-version:5.9\n", "// swift-tools-version:5.9\n" + header, 1))
print("Package.swift written for", tag)
