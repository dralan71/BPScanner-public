# Roboflow Scanner

The Roboflow scanner is BPScanner's primary image-reading path.

## What It Does

`RoboflowVisionService` uploads a resized monitor image to a Roboflow workflow. The workflow returns predictions for display digits and labels. The app then:

- extracts predictions from the nested Roboflow response
- filters low-confidence detections
- groups digit detections into rows
- uses `SYS`, `DIA`, and `PUL` labels when available
- falls back to vertical row order when labels are missing
- validates plausible ranges before accepting a reading

## Why It Works Well Here

This model was trained specifically for blood pressure monitor displays. That matters because seven-segment LCD digits do not behave like normal printed or handwritten text. A detector trained on this display style can recognize segmented numerals and row labels more reliably than general OCR.

## Configuration

Set `ROBOFLOW_API_KEY` in `Config/GeminiSecrets.xcconfig`.

The workflow endpoint is currently defined in `BPScanner/Scanning/RoboflowVisionService.swift`.

## Tests

The unit tests include parser fixtures for:

- label-anchored rows
- unlabeled vertical rows
- nested Roboflow response shapes
- noisy pulse rows

Add parser tests whenever changing grouping, confidence filtering, or row assignment.
