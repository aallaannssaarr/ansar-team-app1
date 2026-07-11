# Design QA

- Source visual truth: `docs/ansar-design-reference.png`
- Implementation screenshot: unavailable in the local workspace
- Target viewport: 390 x 844
- Target state: Arabic RTL home dashboard, employee checked in, branch list selected

## Full-view comparison evidence

The selected visual reference was inspected and implemented as the design source for the Flutter theme, app header, bottom navigation, attendance panel, branch list, summaries, and shared screen components. A rendered Flutter screenshot could not be captured because the local machine does not have a Flutter runtime or Android emulator.

## Focused region comparison evidence

Focused visual comparison is blocked for the same reason. Automated widget coverage was added for the 390px app header, branch status rows, and product details to catch overflow and rendering exceptions when GitHub Actions runs `flutter test`.

## Findings

- [P1] Rendered implementation evidence is unavailable.
  - Location: all Flutter screens.
  - Evidence: the source mock is available, but no locally rendered APK or Flutter surface can be captured.
  - Impact: typography, exact vertical rhythm, and device-specific wrapping cannot be visually signed off yet.
  - Fix: build the APK in GitHub Actions, capture the home screen at a phone-sized viewport, and compare it with the saved reference.

## Comparison history

- Initial pass: implementation completed from the selected reference; visual comparison blocked before the first rendered pass.

## Implementation checklist

- Run `flutter test` and `flutter analyze` in GitHub Actions.
- Install the generated APK and capture the redesigned home screen.
- Compare the capture with `docs/ansar-design-reference.png` and fix any P0/P1/P2 differences.

## Follow-up polish

- Validate Arabic font fallback and line wrapping on the two test phones.
- Validate the compact header and five-item navigation at 360px width.

final result: blocked
