# Security

## Reporting

Please do not open public issues for secrets, privacy, or HealthKit data handling concerns. Report them privately to the project maintainer.

## Secrets

API keys belong in `Config/GeminiSecrets.xcconfig`, which is ignored by git. Do not commit real Roboflow or Gemini keys.

## Privacy

BPScanner processes photos of blood pressure monitors and can write reviewed readings to Apple Health. Changes that affect photo handling, network requests, or HealthKit writes should be reviewed carefully.
