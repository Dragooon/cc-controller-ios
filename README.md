# cc-controller iOS

The native iPhone client for cc-controller, a daemon that lets you watch and steer Claude Code sessions running on your own machines. The controller itself lives in a separate repository; this one holds only the app.

- `ios/` is the app (SwiftUI, Xcode project generated from `ios/project.yml` with XcodeGen) and `ios/CCKit/`, the Swift package with the protocol, relay and presentation logic.
- `scripts/ios.sh` builds, tests, takes screenshots and installs. See [ios/README.md](ios/README.md) for the commands and for the local settings (bundle ID, relay endpoints) that stay out of the repository.

## Requirements

Xcode 27 with the iOS 27 SDK, and XcodeGen (`brew install xcodegen`). UI tests and screenshots also need a checkout of the controller with `npm ci` run in it, found through `CC_CONTROLLER_ROOT` or as a sibling `cc-controller` directory.

## CI

- **CI** (`.github/workflows/ci.yml`) builds the app for the simulator and runs the CCKit tests on every push and pull request.
- **Dev session** (`.github/workflows/dev-session.yml`) is started by hand. It checks out the app and the controller on a macOS runner, joins the owner's tailnet as an ephemeral `tag:ci` node, and starts sshd for the key in the `DEV_SSH_PUBLIC_KEY` variable, so the runner can be used as a remote Mac for builds, simulators and UI tests. It stays up for the requested hours (at most 6) or until `~/stop` exists on the runner.
