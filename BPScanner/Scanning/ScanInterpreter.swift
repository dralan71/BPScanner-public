// MARK: Scanning/ScanInterpreter.swift

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import FoundationModels
import UIKit
@preconcurrency import Vision

/// Service for interpreting blood pressure monitor images.
actor ScanInterpreter {
    private let useGeminiOnly = false
    private let useRoboflowOnly = true
    private let allowGeminiFallback = false
    private let includeRotatedOCRVariants = false
    private let ciContext = CIContext()
    private let displayRegions = [
        CGRect(x: 0.06, y: 0.55, width: 0.58, height: 0.28),
        CGRect(x: 0.06, y: 0.28, width: 0.58, height: 0.26),
        CGRect(x: 0.42, y: 0.03, width: 0.28, height: 0.20),
        CGRect(x: 0.00, y: 0.00, width: 0.74, height: 0.90),
        CGRect(x: 0.00, y: 0.00, width: 1.00, height: 1.00)
    ]
    private let fallbackRegions = [
        CGRect(x: 0.18, y: 0.16, width: 0.52, height: 0.62),
        CGRect(x: 0.14, y: 0.12, width: 0.60, height: 0.70),
        CGRect(x: 0.22, y: 0.10, width: 0.42, height: 0.78),
        CGRect(x: 0.10, y: 0.10, width: 0.74, height: 0.80),
        CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.90),
        CGRect(x: 0.00, y: 0.00, width: 1.00, height: 1.00)
    ]

    /// Analyze a blood pressure monitor image.
    func interpret(image: UIImage) async throws -> BloodPressureReading {
        if let roboflowReading = try await parseWithRoboflow(image: image) {
            NSLog(
                "[DIAGNOSTIC] Roboflow API succeeded. Returning: SYS: %d, DIA: %d, PULSE: %d",
                roboflowReading.systolic,
                roboflowReading.diastolic,
                roboflowReading.pulse ?? 0
            )
            print("[DEBUG] Roboflow API succeeded. Returning: SYS: \(roboflowReading.systolic), DIA: \(roboflowReading.diastolic), PULSE: \(roboflowReading.pulse ?? 0)")
            fflush(stdout)
            return roboflowReading
        }

        if useRoboflowOnly {
            NSLog("[DIAGNOSTIC] Roboflow API did not return a valid reading and local fallback is disabled")
            print("[DEBUG] Roboflow API did not return a valid reading and local fallback is disabled")
            fflush(stdout)
            throw ScanInterpreterError.failedToDecode
        }

        if let sevenSegmentReading = try? await SevenSegmentDisplayReader().extractReading(from: image) {
            do {
                try validatePlausibility(sevenSegmentReading)
                NSLog(
                    "[DIAGNOSTIC] Seven-segment reader succeeded. Returning: SYS: %d, DIA: %d, PULSE: %d",
                    sevenSegmentReading.systolic,
                    sevenSegmentReading.diastolic,
                    sevenSegmentReading.pulse ?? 0
                )
                return sevenSegmentReading
            } catch {
                NSLog("[DIAGNOSTIC] Seven-segment reader produced implausible reading: %@", error.localizedDescription)
            }
        }

        if useGeminiOnly {
            if let geminiReading = try await parseWithGeminiFallback(image: image) {
                return geminiReading
            }

            throw ScanInterpreterError.failedToDecode
        }

        NSLog("[DIAGNOSTIC] Starting OCR...")
        print("[DEBUG] Starting OCR...")
        fflush(stdout)

        do {
            let ocrResult = try await performOCR(image: image)
            NSLog("[DIAGNOSTIC] OCR completed. Score: %.2f, Text length: %ld", ocrResult.score, ocrResult.text.count)
            print("[DEBUG] OCR completed. Variant: \(ocrResult.variant), region: \(ocrResult.regionIndex), mode: \(ocrResult.recognitionLevel.rawValue), content: '\(ocrResult.text)'")
            fflush(stdout)

            if ocrResult.score >= 120 {
                let reading = try await parseLocalOCRResult(ocrResult)
                NSLog("[DIAGNOSTIC] Validation passed. Returning local reading: SYS: %d, DIA: %d, PULSE: %d", reading.systolic, reading.diastolic, reading.pulse ?? 0)
                print("[DEBUG] Validation passed. Returning local reading: SYS: \(reading.systolic), DIA: \(reading.diastolic), PULSE: \(reading.pulse ?? 0)")
                fflush(stdout)
                return reading
            }

            NSLog("[DIAGNOSTIC] OCR text was not trustworthy enough to parse locally; trying Gemini fallback")
            print("[DEBUG] OCR rejected due to weak digit signal; trying Gemini fallback")
            fflush(stdout)
        } catch {
            NSLog("[DIAGNOSTIC] Local OCR path failed: %@", error.localizedDescription)
            print("[DEBUG] Local OCR path failed: \(error)")
            fflush(stdout)
        }

        if allowGeminiFallback, let geminiReading = try await parseWithGeminiFallback(image: image) {
            NSLog("[DIAGNOSTIC] Gemini fallback succeeded. Returning: SYS: %d, DIA: %d, PULSE: %d", geminiReading.systolic, geminiReading.diastolic, geminiReading.pulse ?? 0)
            print("[DEBUG] Gemini fallback succeeded. Returning: SYS: \(geminiReading.systolic), DIA: \(geminiReading.diastolic), PULSE: \(geminiReading.pulse ?? 0)")
            fflush(stdout)
            return geminiReading
        }

        NSLog("[DIAGNOSTIC] Gemini fallback is disabled for local testing")
        print("[DEBUG] Gemini fallback is disabled for local testing")
        fflush(stdout)

        throw ScanInterpreterError.failedToDecode
    }

    private func parseLocalOCRResult(_ ocrResult: OCRCandidate) async throws -> BloodPressureReading {
        if let deterministicReading = parseDeterministicOCRResult(ocrResult) {
            NSLog(
                "[DIAGNOSTIC] Deterministic OCR parser returned: SYS: %d, DIA: %d, PULSE: %d",
                deterministicReading.systolic,
                deterministicReading.diastolic,
                deterministicReading.pulse ?? 0
            )
            print("[DEBUG] Deterministic OCR parser returned: SYS: \(deterministicReading.systolic), DIA: \(deterministicReading.diastolic), PULSE: \(deterministicReading.pulse ?? 0)")
            fflush(stdout)

            try validatePlausibility(deterministicReading)
            return deterministicReading
        }

        NSLog("[DIAGNOSTIC] Starting local LLM parsing...")
        print("[DEBUG] Starting local LLM parsing...")
        fflush(stdout)

        let prompt = """
        You are parsing OCR text from a blood pressure monitor display.

        Requirements:
        1. Only use the numbers that are explicitly present in the OCR text.
        2. Do not invent or complete missing digits.
        3. Systolic and diastolic must come from the OCR text and systolic must be greater than diastolic.
        4. Pulse is optional and should be null if not clearly present.
        5. Ignore brand names, icons, timestamps, labels, and garbage characters.

        Monitor OCR text:
        \(ocrResult.text)
        """

        let session = LanguageModelSession()
        let result = try await session.respond(to: prompt, generating: BloodPressureReading.self)
        let reading = sanitizedReading(result.content, against: ocrResult.text)

        NSLog("[DIAGNOSTIC] Local LLM parsed: SYS: %d, DIA: %d, PULSE: %d", reading.systolic, reading.diastolic, reading.pulse ?? 0)
        print("[DEBUG] Local LLM parsed: SYS: \(reading.systolic), DIA: \(reading.diastolic), PULSE: \(reading.pulse ?? 0)")
        fflush(stdout)

        try validatePlausibility(reading)
        try validateReading(reading, against: ocrResult.text)
        return reading
    }

    private func parseWithRoboflow(image: UIImage) async throws -> BloodPressureReading? {
        let service = RoboflowVisionService()
        guard let result = try await service.extractReading(from: image) else {
            return nil
        }

        let reading = result.reading
        try validatePlausibility(reading)
        return reading
    }

    private func parseWithGeminiFallback(image: UIImage) async throws -> BloodPressureReading? {
        let service = GeminiVisionService()
        guard let result = try await service.extractReading(from: image) else {
            return nil
        }

        guard result.confidence >= 0.7 else {
            return nil
        }

        let reading = result.reading
        try validatePlausibility(reading)
        return reading
    }

    /// Perform OCR on the image using multiple crops, preprocessing variants, and Vision modes.
    private func performOCR(image: UIImage) async throws -> OCRCandidate {
        NSLog("[DIAGNOSTIC] performOCR() starting...")
        print("[DEBUG] performOCR() starting...")
        fflush(stdout)

        guard let cgImage = normalizedCGImage(from: image) else {
            NSLog("[DIAGNOSTIC] Failed to get normalized CGImage from UIImage")
            print("[DEBUG] Failed to get normalized CGImage from UIImage")
            fflush(stdout)
            throw ScanInterpreterError.failedToDecode
        }

        let variants = try await makeOCRInputs(from: cgImage)
        var bestCandidate: OCRCandidate?
        var candidates: [OCRCandidate] = []

        let attemptCount = variants.reduce(0) { $0 + $1.regions.count }
        NSLog("[DIAGNOSTIC] Trying %ld variants across %ld regions...", variants.count, attemptCount)
        print("[DEBUG] Trying \(variants.count) variants across \(attemptCount) regions...")
        fflush(stdout)

        for input in variants {
            for (regionIndex, region) in input.regions.enumerated() {
                for recognitionLevel in [VNRequestTextRecognitionLevel.accurate, .fast] {
                    if let candidate = try await ocr(in: input.image, region: region, regionIndex: regionIndex, variant: input.name, recognitionLevel: recognitionLevel) {
                        NSLog("[DIAGNOSTIC] OCR candidate score %.2f from variant=%@ region=%ld mode=%ld", candidate.score, input.name, regionIndex, recognitionLevel.rawValue)
                        print("[DEBUG] Candidate score \(candidate.score) from variant=\(input.name) region=\(regionIndex) mode=\(recognitionLevel.rawValue) text='\(candidate.text)'")
                        fflush(stdout)

                        candidates.append(candidate)

                        if bestCandidate == nil || candidate.score > bestCandidate!.score {
                            bestCandidate = candidate
                        }
                    }
                }
            }
        }

        if let aggregateCandidate = makeAggregateOCRCandidate(from: candidates) {
            return aggregateCandidate
        }

        if let bestCandidate {
            return bestCandidate
        }

        NSLog("[DIAGNOSTIC] All OCR attempts failed")
        print("[DEBUG] All OCR attempts failed")
        fflush(stdout)
        throw ScanInterpreterError.failedToDecode
    }

    private func ocr(
        in cgImage: CGImage,
        region: CGRect,
        regionIndex: Int,
        variant: String,
        recognitionLevel: VNRequestTextRecognitionLevel
    ) async throws -> OCRCandidate? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.03
        request.regionOfInterest = region

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])

                    let observations = request.results ?? []
                    let lines = observations.compactMap { observation -> OCRLine? in
                        guard let candidate = observation.topCandidates(1).first else {
                            return nil
                        }

                        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else {
                            return nil
                        }

                        return OCRLine(text: text, confidence: candidate.confidence)
                    }

                    guard !lines.isEmpty else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let text = lines.map(\.text).joined(separator: "\n")
                    let score = Self.scoreOCRText(lines)
                    let candidate = OCRCandidate(
                        text: text,
                        score: score,
                        regionIndex: regionIndex,
                        variant: variant,
                        recognitionLevel: recognitionLevel
                    )
                    continuation.resume(returning: candidate)
                } catch {
                    print("[DEBUG] OCR error for variant=\(variant) region=\(regionIndex): \(error)")
                    fflush(stdout)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func makeAggregateOCRCandidate(from candidates: [OCRCandidate]) -> OCRCandidate? {
        guard let bestCandidate = candidates.max(by: { $0.score < $1.score }) else {
            return nil
        }

        let minimumScore = max(25, bestCandidate.score - 170)
        var seenTexts = Set<String>()
        let selectedCandidates = candidates
            .filter { candidate in
                let hasUsefulNumbers = Self.extractDisplayNumberGroups(from: candidate.text).contains { group in
                    guard let value = Int(group) else { return false }
                    return (35...260).contains(value)
                }

                return candidate.score >= minimumScore
                    || hasUsefulNumbers
                    || candidate.text.localizedCaseInsensitiveContains("SYS")
                    || candidate.text.localizedCaseInsensitiveContains("DIA")
                    || candidate.text.localizedCaseInsensitiveContains("PUL")
            }
            .sorted { aggregatePriority($0) > aggregatePriority($1) }
            .filter { candidate in
                let normalized = candidate.text
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !seenTexts.contains(normalized) else {
                    return false
                }

                seenTexts.insert(normalized)
                return true
            }
            .prefix(14)

        let combinedText = selectedCandidates
            .map(\.text)
            .joined(separator: "\n\nOCR candidate\n")

        return OCRCandidate(
            text: combinedText,
            score: bestCandidate.score,
            regionIndex: bestCandidate.regionIndex,
            variant: "\(bestCandidate.variant)+aggregate",
            recognitionLevel: bestCandidate.recognitionLevel
        )
    }

    private func makeOCRInputs(from cgImage: CGImage) async throws -> [OCRInput] {
        var inputs: [OCRInput] = []

        if let displayImage = try await detectDisplayImage(in: cgImage) {
            NSLog("[DIAGNOSTIC] Detected display region for focused OCR")
            print("[DEBUG] Detected display region for focused OCR")
            fflush(stdout)
            inputs.append(contentsOf: makePreprocessedImages(from: displayImage, named: "display").map {
                OCRInput(name: $0.0, image: $0.1, regions: displayRegions)
            })
        } else {
            NSLog("[DIAGNOSTIC] Display detection failed; using full-image fallback")
            print("[DEBUG] Display detection failed; using full-image fallback")
            fflush(stdout)
        }

        inputs.append(contentsOf: makePreprocessedImages(from: cgImage, named: "full").map {
            OCRInput(name: $0.0, image: $0.1, regions: fallbackRegions)
        })

        return inputs
    }

    private func detectDisplayImage(in cgImage: CGImage) async throws -> CGImage? {
        let observations = try await detectRectangles(in: cgImage)

        guard let bestRectangle = observations.max(by: { scoreRectangle($0) < scoreRectangle($1) }) else {
            return nil
        }

        return perspectiveCorrectedImage(from: cgImage, rectangle: bestRectangle)
    }

    private func detectRectangles(in cgImage: CGImage) async throws -> [VNRectangleObservation] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 8
        request.minimumConfidence = 0.5
        request.minimumAspectRatio = 0.35
        request.maximumAspectRatio = 0.9
        request.minimumSize = 0.18
        request.quadratureTolerance = 30

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                    continuation.resume(returning: request.results ?? [])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private func scoreRectangle(_ rectangle: VNRectangleObservation) -> CGFloat {
        let box = rectangle.boundingBox
        let area = box.width * box.height
        let centerX = box.midX
        let centerY = box.midY
        let centerDistance = abs(centerX - 0.5) + abs(centerY - 0.5)
        return area - (centerDistance * 0.35)
    }

    private func perspectiveCorrectedImage(from cgImage: CGImage, rectangle: VNRectangleObservation) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        let corrected = CIFilter.perspectiveCorrection()
        corrected.inputImage = ciImage
        corrected.topLeft = rectangle.topLeft.cgPoint(in: extent)
        corrected.topRight = rectangle.topRight.cgPoint(in: extent)
        corrected.bottomLeft = rectangle.bottomLeft.cgPoint(in: extent)
        corrected.bottomRight = rectangle.bottomRight.cgPoint(in: extent)

        guard let output = corrected.outputImage?.cropped(to: corrected.outputImage?.extent ?? extent) else {
            return nil
        }

        return ciContext.createCGImage(output, from: output.extent)
    }

    private static func scoreOCRText(_ lines: [OCRLine]) -> Double {
        let text = lines.map(\.text).joined(separator: "\n")
        let digitGroups = extractDigitGroups(from: text)
        let threeDigitGroups = digitGroups.filter { $0.count == 3 }
        let twoOrThreeDigitGroups = digitGroups.filter { (2...3).contains($0.count) }
        let averageConfidence = lines.map(\.confidence).reduce(0, +) / Float(lines.count)
        let digitCount = text.filter(\.isNumber).count
        let garbagePenalty = text.filter { !$0.isWhitespace && !$0.isNumber && $0 != "/" && $0 != "-" }.count

        var score = Double(averageConfidence) * 100
        score += Double(threeDigitGroups.count) * 25
        score += Double(twoOrThreeDigitGroups.count) * 10
        score += Double(digitCount) * 2
        score -= Double(garbagePenalty) * 3

        if digitGroups.count >= 2 {
            score += 20
        }
        if likelyContainsReading(groups: digitGroups) {
            score += 40
        }

        let labelCount = ["SYS", "DIA", "PUL"].reduce(0) { partial, label in
            partial + (text.localizedCaseInsensitiveContains(label) ? 1 : 0)
        }
        score += Double(labelCount) * 12

        return score
    }

    private static func likelyContainsReading(groups: [String]) -> Bool {
        let values = groups.compactMap(Int.init)

        for (index, systolic) in values.enumerated() {
            guard (70...260).contains(systolic) else { continue }

            for diastolic in values.dropFirst(index + 1) where (40...160).contains(diastolic) && systolic > diastolic {
                return true
            }
        }

        return false
    }

    private func parseDeterministicOCRResult(_ ocrResult: OCRCandidate) -> BloodPressureReading? {
        if let sequenceReading = parseOrderedSequenceReading(from: ocrResult.text) {
            NSLog(
                "[DIAGNOSTIC] Ordered OCR sequence parser returned: SYS: %d, DIA: %d, PULSE: %d",
                sequenceReading.systolic,
                sequenceReading.diastolic,
                sequenceReading.pulse ?? 0
            )
            return sequenceReading
        }

        let lines = ocrResult.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var systolicScores: [Int: Double] = [:]
        var diastolicScores: [Int: Double] = [:]
        var pulseScores: [Int: Double] = [:]
        let sysLabelIndex = firstLineIndex(containing: "SYS", in: lines)
        let diaLabelIndex = firstLineIndex(containing: "DIA", in: lines)
        let pulLabelIndex = firstLineIndex(containing: "PUL", in: lines) ?? firstLineIndex(containing: "PULSE", in: lines)

        for (lineIndex, line) in lines.enumerated() {
            guard !line.isEmpty, !line.contains(":"), !line.contains("/") else {
                continue
            }

            let groups = Self.extractStrictDisplayNumberGroups(from: line).compactMap(Int.init)
            guard !groups.isEmpty else {
                continue
            }

            let sysContext = contextScore(for: "SYS", around: lineIndex, lines: lines)
            let diaContext = contextScore(for: "DIA", around: lineIndex, lines: lines)
            let pulContext = max(
                contextScore(for: "PUL", around: lineIndex, lines: lines),
                contextScore(for: "PULSE", around: lineIndex, lines: lines)
            )

            for value in groups {
                guard value != 33 else { continue }

                if (70...260).contains(value) {
                    let lengthBonus = String(value).count == 3 ? 3.0 : 0.0
                    let orderBonus = orderScore(valueLineIndex: lineIndex, preferredBefore: sysLabelIndex, preferredAfter: nil)
                    systolicScores[value, default: 0] += 1.0 + lengthBonus + sysContext + orderBonus - (pulContext * 0.4)
                }

                if (40...160).contains(value) {
                    let orderBonus = orderScore(valueLineIndex: lineIndex, preferredBefore: pulLabelIndex, preferredAfter: diaLabelIndex)
                    diastolicScores[value, default: 0] += 1.0 + diaContext + orderBonus - (sysContext * 0.4) - (pulContext * 0.9)
                }

                if (35...220).contains(value) {
                    let orderBonus = orderScore(valueLineIndex: lineIndex, preferredBefore: nil, preferredAfter: pulLabelIndex)
                    pulseScores[value, default: 0] += 0.7 + pulContext + orderBonus - (sysContext * 0.5)
                }
            }
        }

        applyCandidateSequenceScores(
            sections: ocrResult.text.components(separatedBy: "OCR candidate"),
            systolicScores: &systolicScores,
            diastolicScores: &diastolicScores,
            pulseScores: &pulseScores
        )

        guard let systolic = systolicScores.max(by: { $0.value < $1.value })?.key else {
            return nil
        }

        guard let diastolic = diastolicScores
            .filter({ $0.key < systolic })
            .max(by: { lhs, rhs in
                if abs(lhs.value - rhs.value) < 0.75 {
                    return lhs.key > rhs.key
                }
                return lhs.value < rhs.value
            })?.key else {
            return nil
        }

        let bestPulse = pulseScores
            .filter { candidate in
                candidate.key != systolic && candidate.key != diastolic && candidate.value >= 2.5
            }
            .max(by: { $0.value < $1.value })?.key

        guard let pulse = bestPulse else {
            NSLog("[DIAGNOSTIC] Deterministic OCR rejected because pulse was not clear enough")
            return nil
        }

        let reading = BloodPressureReading(systolic: systolic, diastolic: diastolic, pulse: pulse)

        NSLog(
            "[DIAGNOSTIC] Deterministic OCR scores SYS=%@ DIA=%@ PULSE=%@",
            String(describing: systolicScores),
            String(describing: diastolicScores),
            String(describing: pulseScores)
        )

        return reading
    }

    private func aggregatePriority(_ candidate: OCRCandidate) -> Double {
        let text = candidate.text
        let usefulDigitCount = Self.extractDisplayNumberGroups(from: text).filter { group in
            guard let value = Int(group) else { return false }
            return (35...260).contains(value)
        }.count
        let labelCount = ["SYS", "DIA", "PUL"].reduce(0) { partial, label in
            partial + (text.localizedCaseInsensitiveContains(label) ? 1 : 0)
        }

        return candidate.score + Double(usefulDigitCount * 30) + Double(labelCount * 45)
    }

    private func parseOrderedSequenceReading(from text: String) -> BloodPressureReading? {
        let sections = text.components(separatedBy: "OCR candidate")
        var bestReading: BloodPressureReading?
        var bestScore = 0.0

        for (sectionIndex, section) in sections.enumerated() {
            let values = orderedDisplayValues(from: section)
            guard values.count >= 3, values.count <= 5 else { continue }

            for sysIndex in values.indices {
                let systolic = values[sysIndex]
                guard (80...220).contains(systolic) else { continue }

                for diaIndex in values.indices where diaIndex > sysIndex {
                    let diastolic = values[diaIndex]
                    guard (40...120).contains(diastolic), diastolic < systolic else { continue }

                    let pulse = values.dropFirst(diaIndex + 1).first { (35...220).contains($0) }
                    guard let pulse else { continue }

                    let pulseLooksDistinct = pulse != systolic && pulse != diastolic
                    guard pulseLooksDistinct else { continue }

                    let earlySectionBonus = max(0, 8.0 - Double(sectionIndex))
                    let compactnessBonus = max(0, 5.0 - Double(diaIndex - sysIndex))
                    let score = 18.0 + earlySectionBonus + compactnessBonus

                    if score > bestScore {
                        bestScore = score
                        bestReading = BloodPressureReading(
                            systolic: systolic,
                            diastolic: diastolic,
                            pulse: pulse
                        )
                    }

                    break
                }
            }
        }

        return bestReading
    }

    private func applyCandidateSequenceScores(
        sections: [String],
        systolicScores: inout [Int: Double],
        diastolicScores: inout [Int: Double],
        pulseScores: inout [Int: Double]
    ) {
        for section in sections {
            let values = orderedDisplayValues(from: section)
            guard values.count >= 2 else { continue }

            for sysIndex in values.indices {
                let systolic = values[sysIndex]
                guard (80...220).contains(systolic) else { continue }

                systolicScores[systolic, default: 0] += 3.0

                for diaIndex in values.indices where diaIndex > sysIndex {
                    let diastolic = values[diaIndex]
                    guard (40...120).contains(diastolic), diastolic < systolic else { continue }

                    let distancePenalty = Double(diaIndex - sysIndex - 1) * 0.7
                    diastolicScores[diastolic, default: 0] += max(0.5, 4.0 - distancePenalty)

                    if let pulse = values.dropFirst(diaIndex + 1).first(where: { (35...220).contains($0) }) {
                        pulseScores[pulse, default: 0] += 4.0
                    }

                    break
                }
            }
        }
    }

    private func orderedDisplayValues(from text: String) -> [Int] {
        text.components(separatedBy: .newlines).flatMap { line -> [Int] in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains(":"),
                  !trimmed.contains("/"),
                  !trimmed.localizedCaseInsensitiveContains("TIME"),
                  !trimmed.localizedCaseInsensitiveContains("ARRHYTHMIA"),
                  !trimmed.localizedCaseInsensitiveContains("microlife") else {
                return []
            }

            return Self.extractStrictDisplayNumberGroups(from: trimmed).compactMap { group in
                guard let value = Int(group), value != 33, (35...260).contains(value) else {
                    return nil
                }
                return value
            }
        }
    }

    private func firstLineIndex(containing label: String, in lines: [String]) -> Int? {
        lines.firstIndex { $0.uppercased().contains(label.uppercased()) }
    }

    private func orderScore(valueLineIndex: Int, preferredBefore: Int?, preferredAfter: Int?) -> Double {
        var score = 0.0

        if let preferredBefore {
            let distance = preferredBefore - valueLineIndex
            if (1...4).contains(distance) {
                score += Double(5 - distance)
            } else if distance < 0 {
                score -= 1.5
            }
        }

        if let preferredAfter {
            let distance = valueLineIndex - preferredAfter
            if (1...5).contains(distance) {
                score += Double(6 - distance) * 0.75
            } else if distance < 0 {
                score -= 1.5
            }
        }

        return score
    }

    private func contextScore(for label: String, around lineIndex: Int, lines: [String]) -> Double {
        let upperLabel = label.uppercased()
        var score = 0.0

        for offset in -3...3 {
            let index = lineIndex + offset
            guard lines.indices.contains(index) else {
                continue
            }

            if lines[index].uppercased().contains(upperLabel) {
                score = max(score, Double(4 - abs(offset)))
            }
        }

        return score
    }

    private func sanitizedReading(_ reading: BloodPressureReading, against ocrText: String) -> BloodPressureReading {
        let digitGroups = Set(Self.extractDigitGroups(from: ocrText))
        let pulse = reading.pulse.flatMap { digitGroups.contains(String($0)) ? $0 : nil }

        return BloodPressureReading(
            systolic: reading.systolic,
            diastolic: reading.diastolic,
            pulse: pulse
        )
    }

    private func validateReading(_ reading: BloodPressureReading, against ocrText: String) throws {
        let digitGroups = Set(Self.extractDigitGroups(from: ocrText))
        let requiredGroups = [String(reading.systolic), String(reading.diastolic)]

        guard requiredGroups.allSatisfy(digitGroups.contains) else {
            throw ScanInterpreterError.failedToDecode
        }
    }

    private func validatePlausibility(_ reading: BloodPressureReading) throws {
        if reading.systolic < 60 || reading.systolic > 260 {
            throw ScanInterpreterError.implausibleSystolic(reading.systolic)
        }
        if reading.diastolic < 40 || reading.diastolic > 160 {
            throw ScanInterpreterError.implausibleDiastolic(reading.diastolic)
        }
        if reading.systolic <= reading.diastolic {
            throw ScanInterpreterError.failedToDecode
        }
    }

    private static func extractDigitGroups(from text: String) -> [String] {
        let pattern = #"\d{2,3}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else {
                return nil
            }
            return String(text[matchRange])
        }
    }

    private static func extractDisplayNumberGroups(from text: String) -> [String] {
        var groups = extractDigitGroups(from: text)

        let candidatePattern = #"[0-9SIlOo]{2,3}"#
        guard let regex = try? NSRegularExpression(pattern: candidatePattern, options: [.caseInsensitive]) else {
            return groups
        }

        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else {
                continue
            }

            let normalized = String(text[matchRange])
                .replacingOccurrences(of: "S", with: "5", options: .caseInsensitive)
                .replacingOccurrences(of: "I", with: "1", options: .caseInsensitive)
                .replacingOccurrences(of: "l", with: "1")
                .replacingOccurrences(of: "O", with: "0", options: .caseInsensitive)

            guard normalized.contains(where: \.isNumber),
                  normalized.allSatisfy(\.isNumber),
                  !groups.contains(normalized) else {
                continue
            }

            groups.append(normalized)
        }

        return groups
    }

    private static func extractStrictDisplayNumberGroups(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedDecoration = CharacterSet(charactersIn: "'`,.•·-–—_[](){}")
        let compact = trimmed
            .components(separatedBy: allowedDecoration)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard (2...3).contains(compact.count),
              compact.range(of: #"^[0-9SIlOo]+$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return []
        }

        let normalized = compact
            .replacingOccurrences(of: "S", with: "5", options: .caseInsensitive)
            .replacingOccurrences(of: "I", with: "1", options: .caseInsensitive)
            .replacingOccurrences(of: "l", with: "1")
            .replacingOccurrences(of: "O", with: "0", options: .caseInsensitive)

        guard normalized.allSatisfy(\.isNumber) else {
            return []
        }

        return [normalized]
    }

    private func normalizedCGImage(from image: UIImage) -> CGImage? {
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: rendererFormat)
        let renderedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return renderedImage.cgImage
    }

    private func makePreprocessedImages(from cgImage: CGImage, named baseName: String) -> [(String, CGImage)] {
        let baseImage = CIImage(cgImage: cgImage)
        let variants: [(String, CIImage)] = [
            ("\(baseName)-original", baseImage),
            ("\(baseName)-grayscaleContrast", applyColorControls(to: baseImage, saturation: 0, brightness: 0.02, contrast: 2.2)),
            ("\(baseName)-highContrastMono", applyColorControls(to: baseImage, saturation: 0, brightness: 0.06, contrast: 3.0)),
            ("\(baseName)-exposedMono", applyExposure(to: applyColorControls(to: baseImage, saturation: 0, brightness: 0, contrast: 2.6), ev: 0.7))
        ]

        return variants.flatMap { (name, ciImage) -> [(String, CGImage)] in
            guard let rendered = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                return []
            }
            return rotatedVariants(for: rendered, named: name)
        }
    }

    private func rotatedVariants(for cgImage: CGImage, named name: String) -> [(String, CGImage)] {
        let variants = [
            (name, cgImage),
            ("\(name)-rot90", rotatedCGImage(cgImage, orientation: .right)),
            ("\(name)-rot180", rotatedCGImage(cgImage, orientation: .down)),
            ("\(name)-rot270", rotatedCGImage(cgImage, orientation: .left))
        ]

        if !includeRotatedOCRVariants {
            return [(name, cgImage)]
        }

        return variants
        .compactMap { variantName, image in
            guard let image else { return nil }
            return (variantName, image)
        }
    }

    private func rotatedCGImage(_ cgImage: CGImage, orientation: UIImage.Orientation) -> CGImage? {
        normalizedCGImage(from: UIImage(cgImage: cgImage, scale: 1, orientation: orientation))
    }

    private func applyColorControls(to image: CIImage, saturation: Double, brightness: Double, contrast: Double) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = Float(saturation)
        filter.brightness = Float(brightness)
        filter.contrast = Float(contrast)
        return filter.outputImage ?? image
    }

    private func applyExposure(to image: CIImage, ev: Double) -> CIImage {
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        filter.ev = Float(ev)
        return filter.outputImage ?? image
    }
}

extension ScanInterpreter: ScanInterpreting {}

private struct OCRLine {
    let text: String
    let confidence: Float
}

private struct OCRCandidate {
    let text: String
    let score: Double
    let regionIndex: Int
    let variant: String
    let recognitionLevel: VNRequestTextRecognitionLevel
}

private struct OCRInput {
    let name: String
    let image: CGImage
    let regions: [CGRect]
}

private extension CGPoint {
    func cgPoint(in extent: CGRect) -> CGPoint {
        CGPoint(
            x: extent.minX + (x * extent.width),
            y: extent.minY + ((1 - y) * extent.height)
        )
    }
}

enum ScanInterpreterError: LocalizedError {
    case failedToDecode
    case implausibleSystolic(Int)
    case implausibleDiastolic(Int)

    var errorDescription: String? {
        switch self {
        case .failedToDecode:
            return String(localized: "Could not read the monitor clearly. Please retake the photo or enter the reading manually.", bundle: .main)
        case .implausibleSystolic:
            return String(localized: "The systolic value appears invalid. Please enter it manually.", bundle: .main)
        case .implausibleDiastolic:
            return String(localized: "The diastolic value appears invalid. Please enter it manually.", bundle: .main)
        }
    }
}
