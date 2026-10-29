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
