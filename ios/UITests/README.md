# UI tests

The gate runs on the iPhone Duo only: `scripts/ios.sh flows --tier core` before merging, `--tier nightly` on a schedule. The two lists are at the top of `scripts/ios.sh`, and a class that isn't in one doesn't run in that tier.

## Writing a journey

A journey is one test method that walks through what a person does, with one fixture restart and as few launches as the steps allow. Subclass `JourneyTestCase` and name the file `<Name>JourneyFlowTests.swift`. `CommandsJourneyFlowTests.swift` is the model: a comment per step, no accessibility audit and no screenshot per step. `SessionsListJourneyFlowTests` holds the one enforced accessibility audit.

Logic belongs in `ios/CCKit/Tests/CCKitTests`, and a journey checks that the screens use it.

## Posture

`override var posture: DuoPosture { .unfolded }` opens the Duo for that class; the default is folded. Set Up applies it, so it doesn't depend on what ran before. Don't rotate the device in a gate test.

`TEST_RUNNER_HINGE_ANGLE` only reaches tests that call `SimulatorHinge.applyConfiguredAngle()`, which is Motion. Empty means folded.

## Things that only happen on the Duo

- Folded, the window is 466x678 and the content is 382 wide, with an 84 point rail on its right. The rail holds Back, session info and the list's buttons. Back is `app.buttons["BackButton"]`, and `navigationBars.buttons` holds nothing. Use `goBackToSessions(in:)`.
- Open, the window is 951x669 and the size class is regular.
- The Home button doesn't background the app when folded: `app.state` stays foreground and the screen doesn't change. Use `sendToBackground(_:)`, which checks that it really left.
- Sheets put Close on the rail too, so use `app.buttons["Close"]`. Search's cancel is also a Close button.
- A large details sheet doesn't close from its grabber, which only takes it to medium. Tap the dimmed area above it after that.
- An empty text field reports its placeholder as its value. Read a field with `typedText`.
- Lock now closes Settings, so unlocking comes back to the list.
- `XCUIScreen.screens` has two displays. The app is on display 0 folded and display 1 open, and the other one is black. `addScreenshot(named:)` keeps both.

## Lookups

Use a typed query when the element's type is known. `JourneySupport.swift` has the common ones on `XCUIApplication`. Measured on the long session on a GitHub runner, per five reads:

| Lookup | `descendants(matching: .any)` | Typed |
| --- | --- | --- |
| Transcript scroll | 0.15-0.48 s | 0.05-0.09 s |
| Session title | 0.07-0.24 s | 0.04-0.09 s |
| An element that isn't there | 0.25-0.89 s | 0.05-0.09 s |

Use `element(identifier:)` only when the type changes with state. The composer is a text field, not a text view.

## Tools, not gate tests

`MotionFlowTests`, `ScreenshotTests`, `MockScreenshotTests` and `RealControllerSmokeTests` run through `ios.sh motion`, `shots`, `mocks` and `real-smoke`. A plain `flows` run skips Motion, and the others aren't picked up by it.
