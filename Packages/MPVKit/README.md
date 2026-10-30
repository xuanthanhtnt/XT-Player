# MPVKit (XT-Player build)

[MPVKit](https://github.com/mpvkit/MPVKit) 1.1.0-n9.0.2 with **FFmpeg n9.0.2 rebuilt** for XT-Player. Libmpv and the
other libraries are MPVKit's own release binaries; only the seven FFmpeg libraries (`Libavcodec`, `Libavdevice`,
`Libavfilter`, `Libavformat`, `Libavutil`, `Libswresample`, `Libswscale`) come from this repository's release
`deps-ffmpeg-n9.0.2-xt1`.

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

The zips land in `dist/release/` (one `Lib*.xcframework.zip` per library). Upload the seven FFmpeg zips to a new
release of this repository (tag `deps-ffmpeg-…`, not `v…`, so CI and the in-app updater ignore it), then:

```bash
python3 Packages/MPVKit/tools/make_package.py <MPVKit checkout>/Package.swift /tmp/mpvkit-xt/dist/release deps-ffmpeg-n9.0.2-xt1
```
