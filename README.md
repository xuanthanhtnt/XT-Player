<p align="center">
  <img src="Assets/AppIcon.xcassets/AppIcon.appiconset/AppIcon-iOS.png" width="160" alt="XT-Player">
</p>

<h1 align="center">XT-Player</h1>

<p align="center">
  Trình phát media cá nhân cho Apple TV, iPhone/iPad và Mac — 4K · HDR10 · Dolby Vision · Lossless Audio.<br>
  Lõi <b>libmpv</b> (MPVKit) · giải mã phần cứng <b>VideoToolbox</b> · giao diện <b>SwiftUI</b>.
</p>

<p align="center">
  <a href="https://github.com/xuanthanhtnt/XT-Player/actions/workflows/build.yml"><img src="https://github.com/xuanthanhtnt/XT-Player/actions/workflows/build.yml/badge.svg" alt="Build"></a>
</p>

---

## Trạng thái: v0.1 — Proof of Concept

| Hạng mục | Có trong v0.1 |
|---|---|
| Lõi phát | libmpv 0.41 + FFmpeg 9.0.2, `vo=gpu-next` (Vulkan → MoltenVK → Metal), `hwdec=videotoolbox` |
| HDR | HDR10 / HLG passthrough (`target-colorspace-hint`), Dolby Vision P5/P8 qua libplacebo + libdovi, tự tone-map → SDR khi màn hình không hỗ trợ |
| Apple TV | Match Content: tự đổi tần số quét & dải động qua `AVDisplayManager` (khi bật trong Cài đặt tvOS) |
| Âm thanh | TrueHD, DTS-HD MA, DTS:X, E-AC3/Atmos, FLAC 24/192 → PCM đa kênh 5.1/7.1; macOS có bitstream qua HDMI; Night Mode (dynaudnorm) |
| Phụ đề | libass (.ass/.ssa giữ nguyên hiệu ứng), .srt, .vtt, PGS; chọn track; lệch phụ đề ±0.1 s realtime |
| Nguồn | Tệp cục bộ (iOS/iPadOS/macOS), URL HTTP/HTTPS/FTP/RTSP từ NAS (mọi nền tảng); bộ đệm RAM 400 MB (iOS/tvOS) / 1 GB (macOS) |
| Thư viện | SwiftData: danh sách xem gần đây + điểm xem dở (resume) |
| Metadata | Regex parser tên file (tên, năm, SxxEyy, 4K, DV/HDR10/HDR10+, TrueHD Atmos/DTS-HD…) có unit test |

## Tải bản build

Mọi bản build chạy trên **GitHub Actions** (runner macOS 26) — không cần máy Mac.

- **Mỗi lần push**: vào tab **Actions → Build → (run mới nhất) → Artifacts**:
  - `XTPlayer-…-iOS` → `…-unsigned.ipa` (iPhone/iPad)
  - `XTPlayer-…-tvOS` → `…-unsigned.ipa` (Apple TV)
  - `XTPlayer-…-macOS` → `.zip` chứa `XTPlayer.app` (ký ad-hoc)
- **Phát hành**: tạo tag `v0.1.0` (`git tag v0.1.0 && git push origin v0.1.0`) → workflow tự tạo **Release** đính kèm cả 3 tệp.
- Artifact của mỗi run được giữ 30 ngày; Release thì giữ vĩnh viễn. Mỗi run còn tự kiểm tra gói (bundle ID, OS tối thiểu, kiến trúc, icon đã biên dịch, libmpv đã liên kết) và ghi kết quả ở phần *Annotations* của run.

### Cài đặt

- **iOS / iPadOS (sideload)**: file `.ipa` chưa ký — ký lại bằng Apple ID của bạn với [Sideloadly](https://sideloadly.io), AltStore hoặc SideStore.
- **tvOS (sideload)**: dùng công cụ ký/cài có hỗ trợ Apple TV (ví dụ [atvloadly](https://hub.docker.com/r/bitxeno/atvloadly) chạy trên NAS), hoặc Xcode ▸ Devices nếu có Mac. Ổn định nhất vẫn là TestFlight (xem dưới).
- **macOS**: giải nén, kéo `XTPlayer.app` vào Applications, lần đầu chuột phải ▸ **Open** (hoặc `xattr -dr com.apple.quarantine /Applications/XTPlayer.app`).

### TestFlight (tuỳ chọn)

Job `testflight` ký bằng *cloud-managed signing* của Xcode, chỉ cần một App Store Connect API key (quyền **Admin**) — không cần tự quản lý certificate/profile. Thêm vào **Settings ▸ Secrets and variables ▸ Actions**:

| Secret | Giá trị |
|---|---|
| `ASC_KEY_ID` | Key ID của API key |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8` |
| `APPLE_TEAM_ID` | Team ID (10 ký tự) |

Biến (Variables) tuỳ chọn: `BUNDLE_ID` (mặc định `com.xuanthanhtnt.xtplayer`, phải tồn tại trong App Store Connect), `TESTFLIGHT_ON_TAG=true` để tự upload khi tạo tag. Chạy tay: **Actions → Build → Run workflow → tick "testflight"**.

## Cấu trúc

```
XT-Player/
├── .github/workflows/build.yml     # CI/CD: test → build iOS/tvOS/macOS → release / TestFlight
├── .github/scripts/xcodebuild.sh   # chạy xcodebuild, gom log, đổi lỗi biên dịch thành annotation
├── project.yml                     # XcodeGen (CI tự sinh XTPlayer.xcodeproj)
├── Assets/
│   ├── AppIcon.xcassets/           # Icon iOS (sáng/tối/tinted) + macOS
│   ├── AppIcon-tvOS.xcassets/      # Icon parallax 3 lớp (Back · X · Glossy) + Top Shelf
│   ├── Shared.xcassets/            # BrandMark, AccentColor
│   └── Branding/                   # generate_icons.py + SVG gốc
├── Sources/
│   ├── App/                        # @main, entitlements macOS
│   ├── Modules/
│   │   ├── CorePlayer/             # MPVPlayerEngine (libmpv), Metal layer, Match Content, audio session
│   │   ├── NetworkStorage/         # MediaSource (file / URL); SMB/WebDAV/NFS ở v0.2
│   │   ├── MetadataScraper/        # FilenameParser (TMDb ở v0.3)
│   │   └── UIComponents/           # Home, Player, controls (touch / bàn phím / Siri Remote)
│   └── Services/
│       ├── LocalDatabase/          # SwiftData MediaEntry + resume point
│       └── TraktSync/              # v0.5
└── Tests/XTPlayerTests/            # Unit test (chạy trên CI)
```

Logo được sinh bằng code: `python3 Assets/Branding/generate_icons.py` (cần `numpy` và `playwright`) vẽ lại toàn bộ icon từ một nguồn SVG.

## Phát triển trên Mac (không bắt buộc)

```bash
brew install xcodegen
xcodegen generate
open XTPlayer.xcodeproj
```

Khi chạy debug bằng Xcode, tắt *Metal API Validation* (Edit Scheme ▸ Run ▸ Diagnostics) — MoltenVK có thể crash validation khi phát HDR.

## Giới hạn kỹ thuật cần biết

- **tvOS/iOS không cho phép bitstream** TrueHD/DTS ra HDMI với bất kỳ app nào: libmpv giải mã sang PCM đa kênh (lossless, đủ 7.1) — receiver hiển thị "Multi-channel PCM". Riêng đối tượng Atmos/DTS:X sẽ chỉ còn lớp nền 7.1. macOS thì bitstream được (tuỳ chọn `audioPassthrough`).
- **Dolby Vision** được render bởi libplacebo (đọc RPU, tone-map chính xác) và xuất ra dưới dạng HDR10/PQ — TV không bật chế độ "Dolby Vision" như với AVPlayer.
- Nếu cần DV "thật" + Atmos qua Dolby MAT trên Apple TV, có thể cân nhắc thêm backend [AetherEngine](https://github.com/superuser404notfound/AetherEngine) (FFmpeg demux + VideoToolbox + AVPlayer, LGPL) song song với libmpv ở giai đoạn sau.
- MPVKit bản LGPL không có giao thức `smb://`. Đổi product sang `MPVKit-GPL` trong `project.yml` để mpv phát SMB trực tiếp (chịu giấy phép GPL).

## Lộ trình

- [x] **v0.1** — Khung SwiftUI đa nền tảng, logo Đỏ Cam Glossy, libmpv phát 4K HDR10/DV & TrueHD/DTS, CI build cả 3 nền tảng
- [ ] **v0.2** — SMB3 & WebDAV, duyệt NAS
- [ ] **v0.3** — TMDb API v3, Poster Grid
- [ ] **v0.4** — Tối ưu Focus tvOS, OpenSubtitles API
- [ ] **v0.5** — Trakt.tv sync
- [ ] **v1.0** — Bản ổn định tvOS / iOS / macOS
- [ ] **v2.0** — Android TV & Tablet (Jetpack Compose + libmpv-android)
