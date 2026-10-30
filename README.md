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

## Trạng thái: v0.3.0 — thư viện Nhạc & Video ca nhạc, FFmpeg build riêng, nhạc hi-res

| Hạng mục | Có trong v0.2.1 |
|---|---|
| Lõi phát | libmpv 0.41 + **FFmpeg 9.0.2 build riêng** (thêm DSD, WavPack, MLP, S/PDIF, VVC… — xem `Packages/MPVKit`), `vo=gpu-next` (Vulkan → MoltenVK → Metal), **giải mã phần cứng VideoToolbox bật/tắt được** (cả khi đang phát), deinterlace tự động |
| Hình ảnh | **Chất lượng hình ảnh** Cân bằng / Cao / Tối đa: phóng to EWA Lanczos (Tối đa: Lanczos 4 nhánh cho cả màu), khử dải màu, tone-map HDR theo đỉnh sáng từng cảnh; **Chuyển động mượt** (display-resample + oversample: hết giật phim 24p trên màn 60 Hz, không hiệu ứng “phim truyền hình”) |
| HDR | HDR10 / HLG passthrough, Dolby Vision P5/P8 qua libplacebo + libdovi, tone-map → SDR khi màn hình không hỗ trợ |
| Apple TV | Match Content: tự đổi tần số quét & dải động (`AVDisplayManager`) |
| Âm thanh | TrueHD, DTS-HD MA, DTS:X, E-AC3/Atmos → PCM 7.1 lossless; **nhạc hi-res**: FLAC / ALAC / WAV / AIFF tới 24-bit 192 kHz, **DSD (DSF / DFF, SACD DST)**, **WavPack**, APE, TTA, TAK, Musepack, file DTS / TrueHD / MLP rời; phát đúng tần số gốc (Mac: khớp tần số DAC; iPhone/iPad: DAC USB / Lightning), bảng Thông tin cho biết có lấy mẫu lại hay không; macOS **bitstream qua HDMI** (AC3 / E-AC3 / DTS, TrueHD / DTS-HD nếu cổng HDMI nhận); **Tăng thoại** (kênh giữa to hơn, vòm / siêu trầm nhỏ lại; stereo: nâng phần giữa); **Chế độ ban đêm** (nén dải động từ metadata Dolby AC3 / E-AC3); Mac: **khớp tần số lấy mẫu** với DAC; chỉnh lệch tiếng ±50 ms |
| Phụ đề | libass (.ass giữ hiệu ứng), .srt/.vtt/PGS; **tự nạp phụ đề cạnh file trên NAS**; lệch ±0,1 s; cỡ/vị trí/nền chữ |
| Ổ mạng | **SMB2/3** (SMBClient thuần Swift, stream thẳng vào mpv qua `xtsmb://`, không transcode; **4 kết nối song song + đọc trước + cache khối**, tự kết nối lại khi NAS ngắt), **WebDAV** (HTTP/HTTPS, Basic/Digest, chứng chỉ tự ký), **tự tìm NAS bằng Bonjour**; **ảnh thu nhỏ từng video khi duyệt thư mục** (như Infuse), duyệt và phát cả **file nhạc**; mật khẩu trong Keychain |
| Thư viện | Quét thư mục NAS, nhận diện phim / tập, **poster, backdrop, diễn viên, tóm tắt, tên & ảnh từng tập từ TMDb** — chưa có khoá TMDb thì **lấy từ Trakt** (tên & tóm tắt tiếng Việt, poster, diễn viên, tên tập); không có trên TMDb thì **lấy khung hình trong video làm ảnh bìa** (như Infuse); hàng *Tiếp tục xem*, kệ Phim / TV Shows, trang chi tiết, chọn mùa, đánh dấu đã xem |
| Âm nhạc | Mỗi thư mục thư viện có **loại**: Phim & TV / **Video ca nhạc** / **Nhạc** (gợi ý theo tên thư mục, đổi được ở Nguồn ▸ Loại thư mục). Video ca nhạc không tra TMDb/Trakt (không khớp nhầm thành phim), ảnh từ khung hình; Nhạc thành **album** theo thư mục (nghệ sĩ, năm, đĩa CD1/CD2, số bài từ tên file, ảnh bìa cover.jpg hoặc ảnh nhúng), trang album có danh sách bài, Phát / Trộn bài, phát liền mạch sang bài sau; màn hình phát nhạc hiện ảnh bìa |
| Giao diện | Thanh bên (Mac / iPad / Apple TV) hoặc tab (iPhone); trên Mac nhóm kiểu Infuse: Tìm kiếm · Trang chủ · **Thư viện** (Phim, TV Shows, Mới thêm, Chưa xem, Điểm cao, Thể loại) · **Âm nhạc** (Nhạc, Video ca nhạc) · **Tệp** (từng máy chủ & thư mục) · **Cài đặt ghim cuối thanh bên** (⌘,); **banner nổi bật** tự xoay vòng, kệ *Tiếp tục xem* / *Mới thêm*; trang chi tiết kiểu Infuse (ảnh nền lớn, nút *Tiếp tục 00:12:15*, nút vuông, vạch tiến độ) |
| Player | Thanh điều khiển nổi (kính mờ), thanh tua có bong bóng thời gian + tên chương, **bảng ⚙︎ có tab** Âm thanh · Phụ đề · Video · Chương · Thông tin (codec, HDR, bitrate, đầu ra âm thanh, nhật ký libmpv), hàng đợi + **Up Next**, tốc độ 0.5–2×, Fit / Fill / Stretch, Now Playing, chạm đúp / vuốt để tua; **ảnh xem trước khi tua** (scrub thumbnails); **tìm & tải phụ đề OpenSubtitles** ngay trong bảng Phụ đề; **AirPlay lên Apple TV / TV AirPlay** (Mac, iPhone/iPad) |
| Trakt | Đăng nhập bằng mã (cả Apple TV), **scrobble** khi xem, **đồng bộ đã xem và điểm xem tiếp** giữa Mac / iPhone / Apple TV (và Infuse nếu cũng nối Trakt); tự đồng bộ khi mở app, khi đóng trình phát và mỗi 15 phút; lỗi Trakt ghi trong nhật ký trình phát |
| Cập nhật | Tự kiểm tra GitHub Releases mỗi ngày; Mac tải .dmg qua trình duyệt, iPhone/iPad mở trang tải; **Cài đặt ▸ Cập nhật** hoặc menu *Kiểm tra cập nhật…* |
| macOS | Bản cài **.dmg**; trình phát kiểu Infuse (nút *Đóng*, thanh nổi: âm lượng · ⏮ ↺ ▶ ↻ ⏭ · ⚙︎ · cửa sổ nổi · toàn màn hình); **cửa sổ lấy đúng tỉ lệ video — không viền đen**, dải tiêu đề mờ; **cửa sổ nổi** (nhỏ, luôn ở trên); âm lượng + chọn thiết bị phát, rê chuột hiện điều khiển / tự ẩn con trỏ; phím tắt Space ← → ↑ ↓ N M A I T Z X F Esc |

### So với Infuse

Ngang hoặc hơn: định dạng và codec (FFmpeg đầy đủ), phụ đề ASS (libass), SMB/WebDAV trực tiếp, thư viện TMDb, Up Next, mã nguồn mở và tự build trên GitHub.

Còn thiếu so với Infuse (lộ trình):

- **Dolby Vision ở chế độ DV thật của TV và Atmos qua Dolby MAT trên Apple TV.** Cần engine AVPlayer chạy song song với libmpv, và phải test trên thiết bị.
- Đồng bộ iCloud.
- Top Shelf "Tiếp tục xem" trên tvOS.
- Kết nối Plex / Jellyfin / Emby.

### Trakt

Bản phát hành đã kèm Client ID: chỉ cần **Cài đặt ▸ Trakt ▸ Kết nối Trakt** rồi nhập mã. Chỉ phim và tập phim có trên Trakt mới đồng bộ được (video ca nhạc, concert, video gia đình thì không).

Bản tự build: tạo ứng dụng tại trakt.tv/oauth/applications/new (App type: **Development**, Redirect URIs: `http://localhost`), dán **Client ID** (Mã khách hàng) vào **Cài đặt ▸ Trakt** — ứng dụng Trakt tạo từ tháng 10/2026 dùng PKCE và không có Client Secret, để trống ô đó — bấm **Kết nối Trakt** rồi nhập mã hiện ra tại trakt.tv/activate. Có thể đặt secret `TRAKT_CLIENT_ID` / `TRAKT_CLIENT_SECRET` để CI nhúng sẵn (bản build công khai sẽ chứa cặp khoá này).

### OpenSubtitles

Lấy API key miễn phí tại opensubtitles.com ▸ Profile ▸ API Consumers, nhập vào **Cài đặt ▸ Phụ đề trực tuyến** (tuỳ chọn thêm tài khoản để tải nhiều hơn mỗi ngày). Trong trình phát: bảng **Phụ đề ▸ Tìm trên OpenSubtitles…** — tìm theo hash của tệp (khớp đúng bản) và tên phim. Có thể đặt secret `OPENSUBTITLES_API_KEY` để CI nhúng sẵn khoá.

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
│       └── TraktSync/              # Trakt: đăng nhập mã thiết bị, scrobble, đồng bộ đã xem & điểm xem tiếp
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
- Trên tvOS, thư viện được lưu trong thư mục Caches (giới hạn của tvOS). Nếu hệ thống dọn bộ nhớ thì quét lại; nối Trakt để điểm xem dở và trạng thái đã xem được giữ trên Trakt.
- **AirPlay** gửi tệp gốc cho TV (TV tự kéo dữ liệu từ máy bạn qua mạng LAN, không transcode), nên chỉ phát được định dạng AVPlayer hỗ trợ: MP4 / MOV / M4V với H.264 hoặc HEVC (AV1 chỉ trên TV có giải mã AV1). MKV và các định dạng khác: dùng *Phản chiếu màn hình*. Máy và TV phải cùng mạng.
- **Cập nhật trong app** dựa trên GitHub Releases (tạo bằng tag `v*`). Bản Mac mở link .dmg bằng trình duyệt để bạn kéo vào Applications (tệp do app sandbox tự tải bị macOS cách ly cứng, app chép ra từ đó không mở được).

## Lộ trình

- [x] **v0.1**: Khung SwiftUI đa nền tảng, libmpv phát 4K HDR10/DV và TrueHD/DTS, CI build cả 3 nền tảng
- [x] **v0.2**: macOS DMG, SMB3 và WebDAV, Bonjour, thư viện TMDb, Up Next, chapter, Now Playing, Cài đặt
- [x] **v0.2.1**: Logo mới, giao diện kiểu Infuse (thanh bên, banner, bảng track/thông tin), sửa co giãn video & toàn màn hình trên Mac, sửa/chẩn đoán âm thanh
- [x] **v0.2.2**: Stream SMB đa kết nối (hết buffer liên tục với MP4 không xen kẽ), ảnh bìa từ khung hình, AirPlay, kiểm tra & cài bản cập nhật trong app
- [x] **v0.2.3**: macOS chỉnh được âm lượng khi bật Bitstream HDMI (chỉ dùng chế độ độc quyền lúc thật sự bitstream)
- [x] **v0.2.4**: Trakt.tv (scrobble, đã xem, điểm xem tiếp giữa các thiết bị), ảnh xem trước khi tua, phụ đề OpenSubtitles, thời lượng / độ phân giải cho phim không có trên TMDb
- [x] **v0.2.5**: Sửa cập nhật trên Mac (tải .dmg qua trình duyệt — bản 0.2.4 tải trong app bị macOS chặn mở)
- [x] **v0.2.6**: Trakt với ứng dụng PKCE (chỉ cần Client ID, nhúng sẵn qua CI — chỉ bấm Kết nối Trakt rồi nhập mã)
- [x] **v0.2.7**: Ảnh thu nhỏ từng video khi duyệt NAS; ảnh bìa cho file trên máy (WebM…) và WebDAV
- [x] **v0.3.0**: tách Nhạc / Video ca nhạc khỏi Phim (loại thư mục, album theo thư mục, trang album, kệ trên Trang chủ, tab Nhạc trên iPhone/Apple TV), trình duyệt NAS chia mục Video / Nhạc, màn hình phát nhạc có ảnh bìa
- [x] **v0.2.9**: FFmpeg build riêng (DSD, WavPack, MLP, TAK, Musepack, DTS/TrueHD rời, VVC, phụ đề PGS rời / VobSub / SAMI…), bitstream HDMI trên Mac chạy thật, Chế độ ban đêm nén dải động thật (dynaudnorm), Tăng thoại cho stereo (dialoguenhance), nhạc hi-res đúng tần số gốc trên iPhone/iPad/Apple TV, bảng Thông tin hi-res, duyệt & phát file nhạc trên NAS
- [x] **v0.2.8**: chất lượng hình ảnh (Cân bằng / Cao / Tối đa), chuyển động mượt, nút giải mã phần cứng, Tăng thoại, sửa Chế độ ban đêm, khớp tần số lấy mẫu (Mac); sửa Trakt không scrobble; nhận diện phim qua Trakt khi chưa có khoá TMDb; "Chưa xem" chỉ còn mục chưa mở; Cài đặt ghim cuối thanh bên Mac
- [ ] **v0.3**: Engine AVPlayer cho Dolby Vision và Atmos (Apple TV), song song với libmpv
- [ ] **v0.4**: Top Shelf (tvOS), Jellyfin / Emby / Plex
- [ ] **v0.5**: iCloud
- [ ] **v1.0**: Bản ổn định tvOS / iOS / macOS
- [ ] **v2.0**: Android TV và Tablet (Jetpack Compose + libmpv-android)
