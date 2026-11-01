# TraktSync

Trakt.tv REST API (`TraktService.swift`):

- OAuth **device-code** login (works on Apple TV): the user opens trakt.tv/activate and types the code.
  Tokens live in the Keychain and are refreshed a day before they expire.
- **Scrobble** start / pause / stop from the player (`PlayerScreen`); a stop under 80 % leaves a resume point,
  80 % or more marks the item watched.
- **Sync** at launch and from Settings: `/sync/playback` resume points and `/sync/watched/*` history are applied to
  `MediaEntry` when newer than what this device saved; local "watched" Trakt lacks is pushed to `/sync/history`.
- Marking watched / unwatched in the UI (`MediaLibrary.setWatched`) updates Trakt history.

Items are matched by TMDb id when the library has one, else by title + year (movies) or show title + SxxEyy.
Needs the user's Trakt API application (Client ID / Secret) — Settings ▸ Trakt, or the CI secrets
`TRAKT_CLIENT_ID` / `TRAKT_CLIENT_SECRET`.
