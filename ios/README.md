# Native iOS client

The native feedback loop is simulator-only and never opens Simulator.app.

```sh
scripts/ios.sh generate
scripts/ios.sh build
scripts/ios.sh test
scripts/ios.sh shots
scripts/ios.sh shots --device "iPhone 16 Plus" --only sessions
scripts/ios.sh clean
scripts/ios.sh install [--device <udid-or-name>] [--launch]
```

`build`, `test`, `shots`, `mocks`, and `install` regenerate the ignored Xcode project from `ios/project.yml` before doing their work. `shots` starts `scripts/fixture-daemon.mjs`, enrolls a native bearer through the real pairing routes, boots named iOS 27 simulators, runs `ScreenshotTests`, exports PNG attachments into `ios/shots/`, writes a contact sheet, and tears down the fixture and booted simulators. `ios/Config/Signing.local.xcconfig` is optional and ignored; set `DEVELOPMENT_TEAM` there only for physical-device signing.

## Settings

Owner-specific values never go in the repository. `ios/Config/App.xcconfig` holds neutral defaults and includes the ignored `ios/Config/App.local.xcconfig`, which can set:

- `CC_BUNDLE_ID`, the app's bundle ID (default `com.example.cc-controller`). The UI test runner uses `$(CC_BUNDLE_ID).uitests`, and `scripts/ios.sh` reads the same value.
- `CC_RELAY_ENDPOINTS`, the relay addresses a fresh install starts with, separated by spaces. Write `https:/$()/host:port`, because `//` starts a comment in an xcconfig file. Leave it empty to enter the addresses in the app's Settings instead.

`ota` also needs `CC_OTA_HOST`, the host that serves OTA builds (for example `mac.example.ts.net`), from the environment or the ignored `ios/Config/OTA.local.xcconfig`.

Controllers, relay addresses and paired devices are app settings, stored on the phone.

The fixture daemon the UI tests use lives in the controller repository. From a standalone checkout of this app, `scripts/ios.sh` looks for it in `CC_CONTROLLER_ROOT`, or in a `cc-controller` checkout next to this one, with `npm ci` already run there. `install` builds Release, installs on the one paired physical iPhone (or the exact `--device` match), and does not launch it unless `--launch` is passed.

## Composer

An empty composer that isn't focused is one row: attach, the field and send (plus stop while a turn runs). Focusing it, a draft or an attachment brings back the full composer with the model chip on its own row. The field stays in the same place in the view tree in both layouts, so the switch that focusing triggers doesn't rebuild it and drop the keyboard.

## Voice mode

A session's waveform button starts a hands-free conversation when its host reports voice (`GET /api/voice`). The
host transcribes (`POST /api/voice/transcribe`) and speaks (`POST /api/voice/speech`, 24 kHz 16-bit mono PCM); the
phone only records, decides when a turn has ended, plays and keeps the recordings.

- `CCKit/VoiceTurn.swift`: when a turn ends (trailing words hold it 3 s), echo versus barge-in, which transcript
  entries are spoken. `CCKit/SpeakableText.swift`: markdown to spoken sentences; fenced code is read as "Code on
  screen.", a `(skip)` reply isn't spoken. `CCKit/VoiceRecordingArchive.swift`: every utterance, kept on the phone.
- `Sources/CCController/Voice/`: the audio engine (voice processing on, speech-band VAD, AAC utterances, reply
  player, generated cues), the conversation controller, the stage (markdown text, or an image the host serves) and
  the recordings sheet. The app draws nothing itself: a diagram reaches the stage as an image the agent rendered on
  the host (Shitiz, 23 Nov).
- Nothing said is handled as a command; play/pause (AirPods, lock screen, strip) pauses the reply and mutes the mic.
- UI journey: `VoiceModeJourneyFlowTests`, run with `-CCVoiceTestAudio` (no mic on the simulator) against a fixture
  daemon with voice routes (`controller_ref=stockade-next` until the controller's main has them).
- Design: `~/workspace/projects/voice-mode/DESIGN.md` on Mustafar.
- Screen off (24 Nov): voice mode keeps running in the background (UIBackgroundModes audio; the open mic keeps
  the app alive, and pausing mutes rather than stops it). Its controller's store isn't suspended in the background,
  automatic locks (returning after the lock interval, unlock expiry on screen, a failed Face ID) keep that one
  controller signed in so the conversation carries on behind the lock screen, and the resume-new-chat rule skips it.
  "Lock now" and that controller signing out end voice mode.
- AirPods: in a voice-chat session iOS treats a press as a call control, so MPRemoteCommandCenter play/pause only
  comes from the lock screen and Control Center. The press arrives as iOS 17's press-to-mute gesture
  (AVAudioApplication.inputMuteStateChangeNotification); observing it opts in, iOS mutes the mic itself, and voice
  mode pauses with it. App-side pausing calls setInputMuted to stay in step. Not yet tried on the Duo.
- Live Activity (24 Nov): while voice mode runs, the lock screen and Dynamic Island show its status, the sentence
  in play, and pause/end buttons. The widget extension (`Widgets/`, bundle ID `<app>.Widgets`) shares
  `Voice/VoiceActivityShared.swift` with the app; the buttons are LiveActivityIntents, which the system performs in the
  app's process, where VoiceCenter registers the handlers (in the extension they stay empty). The signed build signs
  the extension with secret `CC_WIDGET_PROFILE_BASE64`; without it the install leaves the extension out.
- The LongSession paging failures that first blocked background mode were a transcript bug, not the audio mode: the
  scroll anchor could be the paging row, so an earlier page landing at the top dropped the reader at the top of it.
- Open (23 Nov): on the CI simulator a strip tap that lands just as the agent's turn ends was sometimes lost
  (no pressed state, no action). The journey now waits for the turn to end; watch for it on the Duo.

## TestFlight archive and upload

The one-time owner setup is:

1. Set the Apple Developer **Team ID** in `DEVELOPMENT_TEAM`. It can be exported in the shell or placed in the ignored `ios/Config/Signing.local.xcconfig` as `DEVELOPMENT_TEAM = YOUR_TEAM_ID`.
2. In App Store Connect, create the iOS app record for your bundle ID (`CC_BUNDLE_ID` in `ios/Config/App.local.xcconfig`) and select the same Team ID.
3. Either sign in to the Apple ID in Xcode, or create an App Store Connect API key. For API-key authentication, provide the owner inputs `ASC_KEY_PATH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID`; the `.p8` file stays on the owner's machine.

With those inputs set, run these two commands from the repository root:

```sh
bash scripts/ios.sh archive
bash scripts/ios.sh upload
```

`archive` creates `ios/build/archive/CCController.xcarchive` with a monotonically increasing build number. `upload` exports it for App Store Connect and uploads it using either the API key inputs or the signed-in Xcode account.
