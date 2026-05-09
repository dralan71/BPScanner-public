# Apple OCR and Foundation Models

BPScanner experimented with a local-only scanner using Apple Vision OCR plus Apple Foundation Models.

## Original Idea

The local scanner attempted to:

1. crop likely display regions
2. preprocess the image
3. run Vision text recognition over the crops
4. parse the OCR result deterministically or with a local Foundation Models prompt
5. validate the parsed reading

## Why It Was Discarded

The limiting step was OCR. Blood pressure monitors commonly use seven-segment LCD numbers, where each digit is made from separated bars. Vision OCR is designed for text glyphs, not segmented numeric displays, so it frequently missed digits or produced partial text.

Foundation Models could help parse OCR output when the numbers were present, but it could not reliably infer digits that OCR failed to recognize. For a health-related workflow, guessing missing digits is the wrong behavior.

## Current Status

The code remains useful as a reference and experimentation path, but it is not the recommended primary scanner. Roboflow is the default because it was trained on the target display style.
