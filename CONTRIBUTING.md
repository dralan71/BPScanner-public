# Contributing

Thanks for taking a look at BPScanner. This project is small and practical: changes should keep the scan, review, and HealthKit save flow understandable and easy to verify.

## Getting Started

1. Fork the repository.
2. Open `BPScanner.xcodeproj` in Xcode 26 or newer.
3. Copy `Config/GeminiSecrets.example.xcconfig` to `Config/GeminiSecrets.xcconfig`.
4. Add local API keys only if you are working on cloud scanning.
5. Run the `BPScanner` unit tests before opening a pull request.

## Development Notes

- Do not commit API keys, generated build output, `.derivedData`, or Xcode user data.
- Keep scanner changes covered by tests where possible, especially parser changes.
- Treat all scan output as a suggestion that must be reviewed by the user.
- Avoid broad refactors in scanner code unless they directly improve reliability or testability.

## Pull Requests

Please include:

- A concise description of the change
- What you tested
- Any scanner tradeoffs, new failure modes, or API behavior changes

## Medical Safety

BPScanner is not a diagnostic tool. Contributions should preserve manual review before saving readings and should avoid presenting extracted values as medically authoritative.
