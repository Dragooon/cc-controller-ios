# Native iOS client

The native feedback loop is simulator-only and never opens Simulator.app.

```sh
scripts/ios.sh generate
scripts/ios.sh build
scripts/ios.sh test
scripts/ios.sh shots
scripts/ios.sh shots --device "iPhone 16 Plus" --only sessions
scripts/ios.sh clean
scripts/ios.sh install # intentionally exits 2 until a paired device and team exist
```

`build`, `test`, `shots`, `mocks`, and `install` regenerate the ignored Xcode project from `ios/project.yml` before doing their work. `shots` starts `scripts/fixture-daemon.mjs`, enrolls a native bearer through the real pairing routes, boots named iOS 27 simulators, runs `ScreenshotTests`, exports PNG attachments into `ios/shots/`, writes a contact sheet, and tears down the fixture and booted simulators. `ios/Config/Signing.local.xcconfig` is optional and ignored; set `DEVELOPMENT_TEAM` there only for physical-device signing.

## TestFlight archive and upload

The one-time owner setup is:

1. Set the Apple Developer **Team ID** in `DEVELOPMENT_TEAM`. It can be exported in the shell or placed in the ignored `ios/Config/Signing.local.xcconfig` as `DEVELOPMENT_TEAM = YOUR_TEAM_ID`.
2. In App Store Connect, create the iOS app record for bundle ID `com.example.cc-controller` and select the same Team ID.
3. Either sign in to the Apple ID in Xcode, or create an App Store Connect API key. For API-key authentication, provide the owner inputs `ASC_KEY_PATH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID`; the `.p8` file stays on the owner's machine.

With those inputs set, run these two commands from the repository root:

```sh
bash scripts/ios.sh archive
bash scripts/ios.sh upload
```

`archive` creates `ios/build/archive/CCController.xcarchive` with a monotonically increasing build number. `upload` exports it for App Store Connect and uploads it using either the API key inputs or the signed-in Xcode account.
