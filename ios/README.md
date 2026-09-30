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

`shots` starts `scripts/fixture-daemon.mjs`, enrolls a native bearer through the real pairing routes, boots named iOS 27 simulators, runs `ScreenshotTests`, exports PNG attachments into `ios/shots/`, writes a contact sheet, and tears down the fixture and booted simulators. `ios/Config/Signing.local.xcconfig` is optional and ignored; set `DEVELOPMENT_TEAM` there only for physical-device signing.
