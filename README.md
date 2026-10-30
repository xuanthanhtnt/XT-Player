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

## Trạng thái: v0.2.2 — Stream NAS mượt, AirPlay, tự cập nhật

| Hạng mục | Có trong v0.2.1 |
|---|---|
| Lõi phát | libmpv 0.41 + FFmpeg 9.0.2, `vo=gpu-next` (Vulkan → MoltenVK → Metal), `hwdec=videotoolbox`, deinterlace tự động |
| HDR | HDR10 / HLG passthrough, Dolby Vision P5/P8 qua libplacebo + libdovi, tone-map → SDR khi màn hình không hỗ trợ |
| Apple TV | Match Content: tự đổi tần số quét & dải động (`AVDisplayManager`) |
| Âm thanh | TrueHD, DTS-HD MA, DTS:X, E-AC3/Atmos, FLAC 24/192 → PCM 7.1; macOS bitstream qua HDMI; Night Mode; chỉnh lệch tiếng ±50 ms |
| Phụ đề | libass (.ass giữ hiệu ứng), .srt/.vtt/PGS; **tự nạp phụ đề cạnh file trên NAS**; lệch ±0,1 s; cỡ/vị trí/nền chữ |
| Ổ mạng | **SMB2/3** (SMBClient thuần Swift, stream thẳng vào mpv qua `xtsmb://`, không transcode; **4 kết nối song song + đọc trước + cache khối**, tự kết nối lại khi NAS ngắt), **WebDAV** (HTTP/HTTPS, Basic/Digest, chứng chỉ tự ký), **tự tìm NAS bằng Bonjour**; mật khẩu trong Keychain |
| Thư viện | Quét thư mục NAS, nhận diện phim / tập, **poster, backdrop, diễn viên, tóm tắt, tên & ảnh từng tập từ TMDb**; không có trên TMDb thì **lấy khung hình trong video làm ảnh bìa** (như Infuse); hàng *Tiếp tục xem*, kệ Phim / TV Shows, trang chi tiết, chọn mùa, đánh dấu đã xem |
| Giao diện | Thanh bên (Mac / iPad / Apple TV) hoặc tab (iPhone); trên Mac nhóm kiểu Infuse: Tìm kiếm · Trang chủ · **Thư viện** (Phim, TV Shows, Mới thêm, Chưa xem, Điểm cao, Thể loại) · **Tệp** (từng máy chủ & thư mục) · Cài đặt; **banner nổi bật** tự xoay vòng, kệ *Tiếp tục xem* / *Mới thêm*; trang chi tiết kiểu Infuse (ảnh nền lớn, nút *Tiếp tục 00:12:15*, nút vuông, vạch tiến độ) |
| Player | Thanh điều khiển nổi (kính mờ), thanh tua có bong bóng thời gian + tên chương, **bảng ⚙︎ có tab** Âm thanh · Phụ đề · Video · Chương · Thông tin (codec, HDR, bitrate, đầu ra âm thanh, nhật ký libmpv), hàng đợi + **Up Next**, tốc độ 0.5–2×, Fit / Fill / Stretch, Now Playing, chạm đúp / vuốt để tua; **AirPlay lên Apple TV / TV AirPlay** (Mac, iPhone/iPad) |
| Cập nhật | Tự kiểm tra GitHub Releases mỗi ngày; Mac tải và mở bộ cài .dmg, iPhone/iPad mở trang tải; **Cài đặt ▸ Cập nhật** hoặc menu *Kiểm tra cập nhật…* |
| macOS | Bản cài **.dmg**; trình phát kiểu Infuse (nút *Đóng*, thanh nổi: âm lượng · ⏮ ↺ ▶ ↻ ⏭ · ⚙︎ · cửa sổ nổi · toàn màn hình); **cửa sổ lấy đúng tỉ lệ video — không viền đen**, dải tiêu đề mờ; **cửa sổ nổi** (nhỏ, luôn ở trên); âm lượng + chọn thiết bị phát, rê chuột hiện điều khiển / tự ẩn con trỏ; phím tắt Space ← → ↑ ↓ N M A I T Z X F Esc |

### So với Infuse

Ngang hoặc hơn: định dạng và codec (FFmpeg đầy đủ), phụ đề ASS (libass), SMB/WebDAV trực tiếp, thư viện TMDb, Up Next, mã nguồn mở và tự build trên GitHub.

Còn thiếu so với Infuse (lộ trình):

- **Dolby Vision ở chế độ DV thật của TV và Atmos qua Dolby MAT trên Apple TV.** Cần engine AVPlayer chạy song song với libmpv, và phải test trên thiết bị.
- Đồng bộ Trakt và iCloud.
- Tải phụ đề từ OpenSubtitles.
- Ảnh xem trước khi tua (scrub thumbnails).
- Top Shelf "Tiếp tục xem" trên tvOS.
- Kết nối Plex / Jellyfin / Emby.

### TMDb

Lấy khoá miễn phí tại themoviedb.org ▸ Settings ▸ API, rồi nhập vào **Cài đặt ▸ Thư viện**. App nhận cả *API key (v3)* lẫn *Read Access Token (v4)*.

Bạn cũng có thể đặt secret `TMDB_API_KEY` trong GitHub để CI nhúng sẵn khoá vào bản build. Khi đó khoá nằm trong file `.ipa`/`.dmg` công khai, nên chỉ làm vậy với khoá cá nhân.

## Tải bản build

Mọi bản build chạy trên **GitHub Actions** (runner macOS 26) — không cần máy Mac.

- **Mỗi lần push**: vào tab **Actions → Build → (run mới nhất) → Artifacts**:
  - `XTPlayer-…-iOS` → `…-unsigned.ipa` (iPhone/iPad)
  - `XTPlayer-…-tvOS` → `…-unsigned.ipa` (Apple TV)
  - `XTPlayer-…-macOS` → `.dmg` (kéo XT-Player vào Applications; ký ad-hoc)
- **Phát hành**: tạo tag `v0.1.0` (`git tag v0.1.0 && git push origin v0.1.0`) → workflow tự tạo **Release** đính kèm cả 3 tệp.
- Artifact của mỗi run được giữ 30 ngày; Release thì giữ vĩnh viễn. Mỗi run còn tự kiểm tra gói (bundle ID, OS tối thiểu, kiến trúc, icon đã biên dịch, libmpv đã liên kết) và ghi kết quả ở phần *Annotations* của run.

### Cài đặt

- **iOS / iPadOS (sideload)**: file `.ipa` chưa ký — ký lại bằng Apple ID của bạn với [Sideloadly](https://sideloadly.io), AltStore hoặc SideStore.
- **tvOS (sideload)**: dùng công cụ ký/cài có hỗ trợ Apple TV (ví dụ [atvloadly](https://hub.docker.com/r/bitxeno/atvloadly) chạy trên NAS), hoặc Xcode ▸ Devices nếu có Mac. Ổn định nhất vẫn là TestFlight (xem dưới).
- **macOS**: mở `.dmg`, kéo **XT-Player** vào Applications. Lần đầu chuột phải ▸ **Open** (hoặc chạy `xattr -dr com.apple.quarantine /Applications/XT-Player.app`), vì bản build chỉ ký ad-hoc, không notarize.

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
├── .github/scripts/make-dmg.sh     # đóng gói DMG cho macOS
├── project.yml                     # XcodeGen (CI tự sinh XTPlayer.xcodeproj)
├── Config/Info.plist               # Bonjour, ATS, khoá TMDb build-time
├── Assets/
│   ├── AppIcon.xcassets/           # Icon iOS (sáng/tối/tinted) + macOS
│   ├── AppIcon-tvOS.xcassets/      # Icon parallax 3 lớp (Back · X · Glossy) + Top Shelf
│   ├── Shared.xcassets/            # BrandMark, AccentColor
│   └── Branding/                   # generate_icons.py, SVG gốc, nền DMG
├── Sources/
│   ├── App/                        # @main, entitlements macOS
│   ├── Modules/
│   │   ├── CorePlayer/             # MPVPlayerEngine, xtsmb:// stream bridge, hàng đợi, Now Playing, Match Content
│   │   ├── NetworkStorage/         # SMB2/3, WebDAV, Bonjour, MediaSource
│   │   ├── MetadataScraper/        # FilenameParser, TMDb client, LibraryScanner
│   │   └── UIComponents/           # Home, thư viện, chi tiết, duyệt NAS, Cài đặt, Player
│   └── Services/
│       ├── LocalDatabase/          # SwiftData: MediaEntry, MediaServer, LibraryItem/File/Folder
│       ├── Settings/               # AppSettings, Keychain
│       └── TraktSync/              # (sau)
└── Tests/XTPlayerTests/            # Unit test (chạy trên CI)
```

Logo (thiết kế của chủ dự án) nằm ở `Assets/Branding/xt-mark-source.png`. `python3 Assets/Branding/prepare_mark.py` tách nền (cần `opencv-python`), rồi `python3 Assets/Branding/generate_icons.py` (cần `numpy` và `playwright`) sinh toàn bộ icon iOS / macOS / tvOS, Top Shelf, logo trong app và nền DMG.

## Phát triển trên Mac (không bắt buộc)

```bash
brew install xcodegen
xcodegen generate
open XTPlayer.xcodeproj
```

Khi chạy debug bằng Xcode, tắt *Metal API Validation* (Edit Scheme ▸ Run ▸ Diagnostics) — MoltenVK có thể crash validation khi phát HDR.

## Báo lỗi phát (không tiếng, không hình…)

Mở **Cài đặt ▸ Nhật ký trình phát** (hoặc nút ⓘ trong player ▸ *Nhật ký libmpv*) ngay sau khi phát lỗi, bấm **Sao chép nhật ký** và gửi kèm khi báo lỗi. Bảng ⓘ cũng cho biết đầu ra âm thanh đang dùng — nếu ghi *"Chưa mở — không có tiếng"* thì thử chọn thiết bị khác trong bảng Âm thanh & Phụ đề (Mac).

## Giới hạn kỹ thuật cần biết

- **tvOS/iOS không cho phép bitstream** TrueHD/DTS ra HDMI với bất kỳ app nào: libmpv giải mã sang PCM đa kênh (lossless, đủ 7.1) — receiver hiển thị "Multi-channel PCM". Riêng đối tượng Atmos/DTS:X sẽ chỉ còn lớp nền 7.1. macOS thì bitstream được (tuỳ chọn `audioPassthrough`).
- **Dolby Vision** được render bởi libplacebo (đọc RPU, tone-map chính xác) và xuất ra dưới dạng HDR10/PQ — TV không bật chế độ "Dolby Vision" như với AVPlayer.
- Nếu cần DV "thật" + Atmos qua Dolby MAT trên Apple TV, có thể cân nhắc thêm backend [AetherEngine](https://github.com/superuser404notfound/AetherEngine) (FFmpeg demux + VideoToolbox + AVPlayer, LGPL) song song với libmpv ở giai đoạn sau.
- SMB đi qua cầu `xtsmb://` của app (SMBClient, MIT), nên vẫn giữ được MPVKit bản LGPL. NFS chưa hỗ trợ.
- Trên tvOS, thư viện được lưu trong thư mục Caches (giới hạn của tvOS). Nếu hệ thống dọn bộ nhớ thì quét lại; điểm xem dở sẽ được giữ bền vững khi có đồng bộ Trakt hoặc iCloud.
- **AirPlay** gửi tệp gốc cho TV (TV tự kéo dữ liệu từ máy bạn qua mạng LAN, không transcode), nên chỉ phát được định dạng AVPlayer hỗ trợ: MP4 / MOV / M4V với H.264 hoặc HEVC (AV1 chỉ trên TV có giải mã AV1). MKV và các định dạng khác: dùng *Phản chiếu màn hình*. Máy và TV phải cùng mạng.
- **Cập nhật trong app** dựa trên GitHub Releases (tạo bằng tag `v*`). Bản Mac là app sandbox nên không tự thay chính nó: app tải .dmg và mở bộ cài, bạn kéo vào Applications.

## Lộ trình

- [x] **v0.1**: Khung SwiftUI đa nền tảng, libmpv phát 4K HDR10/DV và TrueHD/DTS, CI build cả 3 nền tảng
- [x] **v0.2**: macOS DMG, SMB3 và WebDAV, Bonjour, thư viện TMDb, Up Next, chapter, Now Playing, Cài đặt
- [x] **v0.2.1**: Logo mới, giao diện kiểu Infuse (thanh bên, banner, bảng track/thông tin), sửa co giãn video & toàn màn hình trên Mac, sửa/chẩn đoán âm thanh
- [x] **v0.2.2**: Stream SMB đa kết nối (hết buffer liên tục với MP4 không xen kẽ), ảnh bìa từ khung hình, AirPlay, kiểm tra & cài bản cập nhật trong app
- [ ] **v0.3**: Engine AVPlayer cho Dolby Vision và Atmos (Apple TV), song song với libmpv
- [ ] **v0.4**: OpenSubtitles, scrub thumbnails, Top Shelf
- [ ] **v0.5**: Trakt.tv sync, iCloud
- [ ] **v1.0**: Bản ổn định tvOS / iOS / macOS
- [ ] **v2.0**: Android TV và Tablet (Jetpack Compose + libmpv-android)
