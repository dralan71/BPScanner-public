# Gemini Scanner

The Gemini scanner is an alternate cloud scanner for monitor photos.

## What It Does

`GeminiVisionService` uploads a resized JPEG to Gemini and requests a structured JSON response:

- `systolic`
- `diastolic`
- `pulse`
- `pulseVisible`
- `confidence`
- `reason`

The app accepts Gemini results only when confidence is high enough and the parsed reading passes plausibility validation.

## Strengths

Gemini can evaluate the whole image, ignore casing text and labels, and return structured output even when the display is not perfectly framed. It is useful as a fallback or comparison path.

## Tradeoffs

Gemini is a general vision model rather than a model trained only on blood pressure monitor displays. It can work well, but the app should continue to validate results and require user review before saving.

## Configuration

Set `GEMINI_API_KEY` in `Config/GeminiSecrets.xcconfig`.

The default endpoint is `gemini-2.5-flash:generateContent`.
