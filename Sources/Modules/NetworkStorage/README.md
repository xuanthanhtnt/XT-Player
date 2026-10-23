# NetworkStorage

- **v0.1** — `MediaSource`: local files (security-scoped bookmarks) and direct URLs (HTTP/HTTPS/FTP/RTSP) streamed by FFmpeg.
- **v0.2** — SMB2/SMB3 (AMSMB2), WebDAV and NFS browsers; streaming into mpv through a `stream_cb` bridge so
  no transcoding server is needed. Alternative: switch the MPVKit product to `MPVKit-GPL`, whose FFmpeg has
  libsmbclient and plays `smb://` URLs natively (GPL licence applies).
