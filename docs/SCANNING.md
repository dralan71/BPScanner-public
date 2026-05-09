# Scanning Overview

BPScanner has several scanner paths in the codebase, but they are not equally important.

## Current Default: Roboflow

Roboflow is the primary scanner. It calls a Roboflow workflow backed by a custom model trained for blood pressure monitor screens. The model detects individual digits and labels such as `SYS`, `DIA`, and `PUL`; the app then assembles those detections into a reading and validates plausible ranges.

Why it is the default:

- It is tuned to the visual structure of blood pressure monitors.
- It can use label positions to assign rows correctly.
- It avoids relying on generic OCR for segmented LCD digits.
- Parser behavior is testable with raw prediction fixtures.

Implementation: `BPScanner/Scanning/RoboflowVisionService.swift`

## Supported Alternative: Gemini

Gemini Vision also works for reading monitor photos. The app sends a resized image to Gemini and asks for structured JSON containing systolic, diastolic, pulse, confidence, and a short reason.

Gemini is useful as an alternative or fallback because it can reason over the whole image. It is less specialized than the Roboflow model, so BPScanner only accepts Gemini readings above a confidence threshold and still validates the result before returning it.

Implementation: `BPScanner/Scanning/GeminiVisionService.swift`

## Discarded Primary Path: Apple OCR Plus Foundation Models

The app includes earlier local scanning experiments using Apple Vision OCR and Apple Foundation Models. The idea was to OCR candidate display regions, then parse the OCR text locally.

This was discarded as the primary approach because Vision OCR was not reliable on seven-segment LCD numbers. Seven-segment displays are made of disconnected bars, not normal text glyphs, and OCR often missed digits or confused partial segments. Foundation Models could parse text when OCR output was good, but it could not recover numbers that OCR never recognized correctly.

Implementation references:

- `BPScanner/Scanning/ScanInterpreter.swift`
- `BPScanner/Scanning/OCRService.swift`
- `BPScanner/Scanning/SevenSegmentDisplayReader.swift`

## Runtime Selection

`ScanInterpreter` currently prefers Roboflow and disables local fallback in the checked-in settings:

```swift
private let useRoboflowOnly = true
private let allowGeminiFallback = false
```

To experiment with another path, change these flags locally and make sure the review screen still requires user confirmation before saving.
