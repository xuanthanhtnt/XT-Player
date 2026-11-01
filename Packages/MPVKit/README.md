# MPVKit (XT-Player build)

[MPVKit](https://github.com/mpvkit/MPVKit) 1.1.0-n9.0.2 with **FFmpeg n9.0.2 and libmpv 0.41 rebuilt** for XT-Player.
The seven FFmpeg libraries (`Libavcodec`, `Libavdevice`, `Libavfilter`, `Libavformat`, `Libavutil`, `Libswresample`,
`Libswscale`) and `Libmpv` come from this repository's releases; the other libraries are MPVKit's own release binaries.

libmpv carries `mpv-build.patch`: mpv's CoreAudio hotplug fixes from after 0.41 (a failed audio output init left a
device listener on freed memory, and the next device change, such as the display going to sleep, crashed the app).

Upstream MPVKit trims FFmpeg to keep the binaries small. XT-Player adds back:

| | Added |
|---|---|
| Audio decoders | DSD (`dsd_*`, SACD `dst`), WavPack, DVD-Audio MLP, TAK, Musepack, Shorten, MPEG-4 ALS |
| Demuxers | DSF, DFF (`iff`), WavPack, Wave64, TTA, TAK, Musepack, Shorten, xWMA, raw DTS / DTS-HD / TrueHD / MLP, S/PDIF in WAV, PGS (`.sup`), VobSub, MicroDVD / SubViewer / SAMI / RealText / VPlayer / PJS / STL / JACOsub / LRC, MXF, NUT, IVF, OBU, VVC, WTV |
| Muxers | `spdif` (mpv's HDMI bitstreaming of AC3 / E-AC3 / DTS / DTS-HD / TrueHD) |
| Video decoders | H.266 / VVC, Theora, MS-MPEG4, DNxHD, CineForm, Cinepak, QuickTime RLE, Ut Video, MagicYUV, JPEG 2000; PNG / BMP / GIF / WebP (cover art) |
| Subtitle decoders | MicroDVD, SubViewer, SAMI, RealText, VPlayer, PJS, STL, JACOsub, plain text, HDMV text |
| Audio filters | `dynaudnorm`, `loudnorm`, `acompressor`, `alimiter`, `compand`, `speechnorm`, `dialoguenhance`, `surround`, `extrastereo`, `stereotools`, `earwax`, `asoftclip`, `highpass`, `lowpass`, `bass`, `treble` |

The build stays LGPL v3 (`--enable-version3`, no GPL parts).

## Rebuilding

The source path must not contain spaces (FFmpeg's configure refuses out-of-tree builds there).

```bash
git clone --branch 1.1.0-n9.0.2 https://github.com/mpvkit/MPVKit /tmp/mpvkit-xt
cd /tmp/mpvkit-xt
git apply /path/to/XT-Player/Packages/MPVKit/ffmpeg-build.patch
brew install wget meson ninja nasm glslang cmake
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build platform=macos,ios,tvos
```

libmpv: in `Sources/BuildScripts/XCFrameworkBuild/main.swift`, after FFmpeg, build `BuildUchardet`, `BuildBluray`,
`BuildLuaJIT` and `BuildMPV` (as MPVKit's own script does), with the diff part of `mpv-build.patch` (from
`diff --git` on) saved as `Sources/BuildScripts/patch/libmpv/0004-coreaudio-hotplug-after-init.patch`. Add
`platform=…,isimulator,tvsimulator` for the simulator slices, and point `TMPDIR` at the build volume: meson stops with
error 28 when the system disk fills up.

The zips land in `dist/release/` (one `Lib*.xcframework.zip` per library). Upload the eight zips (FFmpeg and Libmpv)
to a new release of this repository (tag `deps-…`, not `v…`, so CI and the in-app updater ignore it), then:

```bash
python3 Packages/MPVKit/tools/make_package.py Packages/MPVKit/Package.swift /tmp/mpvkit-xt/dist/release <tag>
```

`--local` instead of the tag points the package at `Packages/MPVKit/local/<name>.xcframework` to test a build first.
