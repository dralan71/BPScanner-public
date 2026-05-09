// MARK: Scanning/RoboflowVisionService.swift

import Foundation
import UIKit

actor RoboflowVisionService {
    private let session: URLSession = .shared
    private let endpoint = URL(string: "https://serverless.roboflow.com/alans-workspace-4mjty/workflows/bpscanner-v2")!

    func extractReading(from image: UIImage) async throws -> RoboflowVisionResult? {
        guard let apiKey = loadAPIKey(),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let uploadImage = await image.resizedForRoboflowUpload()
        guard let imageData = uploadImage.jpegData(compressionQuality: 0.82) else {
            return nil
        }

        let requestBody: [String: Any] = [
            "api_key": apiKey,
            "inputs": [
                "image": [
                    "type": "base64",
                    "value": imageData.base64EncodedString()
                ]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RoboflowVisionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw RoboflowVisionError.api(body)
        }

        let json = try JSONSerialization.jsonObject(with: data)
        let predictions = Self.findPredictions(in: json)
        let digitCount = predictions.filter { $0.kind.digit != nil }.count
        let labelCount = predictions.filter { $0.kind.label != nil }.count
        NSLog("[ROBOFLOW] Found %ld digit predictions and %ld label predictions", digitCount, labelCount)

        guard let reading = Self.makeReading(from: predictions) else {
            return nil
        }

        return RoboflowVisionResult(reading: reading, confidence: Self.averageConfidence(for: predictions))
    }

    private func loadAPIKey() -> String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        return plist["ROBOFLOW_API_KEY"] as? String
    }

    private static func makeReading(from predictions: [RoboflowPrediction]) -> BloodPressureReading? {
        let usable = predictions
            .filter { $0.confidence >= 0.25 }
            .sorted { lhs, rhs in
                if abs(lhs.centerY - rhs.centerY) > 18 {
                    return lhs.centerY < rhs.centerY
                }
                return lhs.centerX < rhs.centerX
            }

        let digitPredictions = usable.filter { $0.kind.digit != nil }
        let labelPredictions = usable.compactMap { prediction -> RoboflowLabelPrediction? in
            guard let label = prediction.kind.label else { return nil }
            return RoboflowLabelPrediction(label: label, prediction: prediction)
        }

        guard digitPredictions.count >= 4 else {
            return nil
        }

        let rows = groupRows(from: digitPredictions)
            .map { row in row.sorted { $0.centerX < $1.centerX } }
            .flatMap(candidateRows)
            .filter { (35...260).contains($0.value) }
            .sorted { lhs, rhs in
                let lhsY = lhs.predictions.map(\.centerY).reduce(0, +) / Double(lhs.predictions.count)
                let rhsY = rhs.predictions.map(\.centerY).reduce(0, +) / Double(rhs.predictions.count)
                return lhsY < rhsY
            }

        NSLog("[ROBOFLOW] Rows: %@", rows.map { "\($0.value):\(String(format: "%.2f", $0.confidence))" }.joined(separator: ", "))

        if let anchoredReading = makeAnchoredReading(from: rows, labels: labelPredictions) {
            NSLog(
                "[ROBOFLOW] Label-anchored reading: SYS=%d DIA=%d PUL=%d",
                anchoredReading.systolic,
                anchoredReading.diastolic,
                anchoredReading.pulse ?? 0
            )
            return anchoredReading
        }

        guard rows.count >= 2 else {
            return nil
        }

        for sysIndex in rows.indices {
            let systolic = rows[sysIndex]
            guard (70...260).contains(systolic.value) else { continue }

            for diaIndex in rows.indices where diaIndex > sysIndex {
                let diastolic = rows[diaIndex]
                guard (40...160).contains(diastolic.value), diastolic.value < systolic.value else {
                    continue
                }

                let pulse = rows.dropFirst(diaIndex + 1).first { row in
                    (35...220).contains(row.value) && row.value != systolic.value && row.value != diastolic.value
                }

                return BloodPressureReading(
                    systolic: systolic.value,
                    diastolic: diastolic.value,
                    pulse: pulse?.value
                )
            }
        }

        return nil
    }

    private static func candidateRows(from row: [RoboflowPrediction]) -> [RoboflowDigitRow] {
        guard row.count >= 2 else { return [] }

        if row.count <= 3, let candidate = makeDigitRow(from: row) {
            return [candidate]
        }

        var candidates: [RoboflowDigitRow] = []
        let maxWindowLength = min(3, row.count)

        for length in 2...maxWindowLength {
            guard row.count >= length else { continue }

            for startIndex in 0...(row.count - length) {
                let window = Array(row[startIndex..<(startIndex + length)])
                guard let candidate = makeDigitRow(from: window),
                      candidate.hasConsistentDigitScale else {
                    continue
                }
                candidates.append(candidate)
            }
        }

        return candidates
    }

    private static func makeDigitRow(from predictions: [RoboflowPrediction]) -> RoboflowDigitRow? {
        guard (2...3).contains(predictions.count) else { return nil }

        let text = predictions.compactMap(\.kind.digit).joined()
        guard text.count == predictions.count,
              let value = Int(text) else {
            return nil
        }

        let confidence = predictions.map(\.confidence).reduce(0, +) / Double(predictions.count)
        return RoboflowDigitRow(value: value, confidence: confidence, predictions: predictions)
    }

    private static func makeAnchoredReading(
        from rows: [RoboflowDigitRow],
        labels: [RoboflowLabelPrediction]
    ) -> BloodPressureReading? {
        guard !labels.isEmpty else { return nil }

        var assignedRows: [RoboflowReadingLabel: RoboflowDigitRow] = [:]
        var usedRowIDs: Set<String> = []

        for label in labels.sorted(by: { $0.prediction.confidence > $1.prediction.confidence }) {
            guard assignedRows[label.label] == nil,
                  let row = closestRow(to: label, in: rows, excluding: usedRowIDs),
                  isValue(row.value, plausibleFor: label.label) else {
                continue
            }

            assignedRows[label.label] = row
            usedRowIDs.insert(row.id)
        }

        guard let systolic = assignedRows[.systolic]?.value,
              let diastolic = assignedRows[.diastolic]?.value,
              (70...260).contains(systolic),
              (40...160).contains(diastolic),
              diastolic < systolic else {
            return nil
        }

        let pulse = assignedRows[.pulse]?.value
        if let pulse, !(35...220).contains(pulse) {
            return nil
        }

        return BloodPressureReading(systolic: systolic, diastolic: diastolic, pulse: pulse)
    }

    private static func closestRow(
        to label: RoboflowLabelPrediction,
        in rows: [RoboflowDigitRow],
        excluding usedRowIDs: Set<String>
    ) -> RoboflowDigitRow? {
        rows
            .filter { row in
                !usedRowIDs.contains(row.id) && row.isHorizontallyAligned(with: label.prediction)
            }
            .min { lhs, rhs in
                lhs.anchorDistance(to: label.prediction) < rhs.anchorDistance(to: label.prediction)
            }
    }

    private static func isValue(_ value: Int, plausibleFor label: RoboflowReadingLabel) -> Bool {
        switch label {
        case .systolic:
            return (70...260).contains(value)
        case .diastolic:
            return (40...160).contains(value)
        case .pulse:
            return (35...220).contains(value)
        }
    }

    private static func groupRows(from predictions: [RoboflowPrediction]) -> [[RoboflowPrediction]] {
        var rows: [[RoboflowPrediction]] = []

        for prediction in predictions {
            if let rowIndex = rows.firstIndex(where: { row in
                let averageY = row.map(\.centerY).reduce(0, +) / Double(row.count)
                let averageHeight = row.map(\.height).reduce(0, +) / Double(row.count)
                return abs(prediction.centerY - averageY) <= max(14, averageHeight * 0.55)
            }) {
                rows[rowIndex].append(prediction)
            } else {
                rows.append([prediction])
            }
        }

        return rows
    }

    private static func averageConfidence(for predictions: [RoboflowPrediction]) -> Double {
        guard !predictions.isEmpty else { return 0 }
        return predictions.map(\.confidence).reduce(0, +) / Double(predictions.count)
    }

    nonisolated private static func findPredictions(in value: Any) -> [RoboflowPrediction] {
        var predictions: [RoboflowPrediction] = []

        if let dictionary = value as? [String: Any] {
            if let prediction = RoboflowPrediction(dictionary: dictionary) {
                predictions.append(prediction)
            }

            for child in dictionary.values {
                predictions.append(contentsOf: findPredictions(in: child))
            }
        } else if let array = value as? [Any] {
            for child in array {
                predictions.append(contentsOf: findPredictions(in: child))
            }
        }

        return predictions
    }

    nonisolated static func makeReadingForTesting(fromRawPredictions rawPredictions: [[String: Any]]) -> BloodPressureReading? {
        makeReading(from: rawPredictions.compactMap(RoboflowPrediction.init(dictionary:)))
    }

    nonisolated static func makeReadingForTesting(fromRawResponse rawResponse: Any) -> BloodPressureReading? {
        makeReading(from: findPredictions(in: rawResponse))
    }
}

struct RoboflowVisionResult {
    let reading: BloodPressureReading
    let confidence: Double
}

private struct RoboflowPrediction {
    let kind: RoboflowPredictionKind
    let confidence: Double
    let centerX: Double
    let centerY: Double
    let width: Double
    let height: Double

    nonisolated init?(dictionary: [String: Any]) {
        let rawClass = dictionary["class"] ?? dictionary["class_name"] ?? dictionary["label"]
        guard let classText = rawClass as? String,
              let kind = RoboflowPredictionKind(classText: classText) else {
            return nil
        }

        guard let x = Self.doubleValue(for: "x", in: dictionary) ?? Self.doubleValue(for: "center_x", in: dictionary),
              let y = Self.doubleValue(for: "y", in: dictionary) ?? Self.doubleValue(for: "center_y", in: dictionary) else {
            return nil
        }

        self.kind = kind
        self.confidence = Self.doubleValue(for: "confidence", in: dictionary) ?? 1
        self.centerX = x
        self.centerY = y
        self.width = Self.doubleValue(for: "width", in: dictionary) ?? Self.doubleValue(for: "w", in: dictionary) ?? 1
        self.height = Self.doubleValue(for: "height", in: dictionary) ?? Self.doubleValue(for: "h", in: dictionary) ?? 1
    }

    nonisolated private static func doubleValue(for key: String, in dictionary: [String: Any]) -> Double? {
        if let value = dictionary[key] as? Double {
            return value
        }
        if let value = dictionary[key] as? Int {
            return Double(value)
        }
        if let value = dictionary[key] as? String {
            return Double(value)
        }
        return nil
    }
}

private struct RoboflowDigitRow {
    let value: Int
    let confidence: Double
    let predictions: [RoboflowPrediction]

    nonisolated var id: String {
        predictions
            .map { "\(Int($0.centerX.rounded())):\(Int($0.centerY.rounded()))" }
            .joined(separator: "|")
    }

    nonisolated var centerX: Double {
        predictions.map(\.centerX).reduce(0, +) / Double(predictions.count)
    }

    nonisolated var centerY: Double {
        predictions.map(\.centerY).reduce(0, +) / Double(predictions.count)
    }

    nonisolated var averageHeight: Double {
        predictions.map(\.height).reduce(0, +) / Double(predictions.count)
    }

    nonisolated var hasConsistentDigitScale: Bool {
        guard let minHeight = predictions.map(\.height).min(),
              let maxHeight = predictions.map(\.height).max(),
              minHeight > 0 else {
            return true
        }

        return maxHeight / minHeight <= 2.6
    }

    nonisolated func isHorizontallyAligned(with prediction: RoboflowPrediction) -> Bool {
        abs(centerY - prediction.centerY) <= max(18, max(averageHeight, prediction.height) * 0.70)
    }

    nonisolated func anchorDistance(to prediction: RoboflowPrediction) -> Double {
        let verticalDistance = abs(centerY - prediction.centerY)
        let horizontalDistance = max(0, abs(centerX - prediction.centerX) - ((averageWidth + prediction.width) / 2))
        return verticalDistance * 2.5 + horizontalDistance
    }

    nonisolated private var averageWidth: Double {
        predictions.map(\.width).reduce(0, +) / Double(predictions.count)
    }
}

private struct RoboflowLabelPrediction {
    let label: RoboflowReadingLabel
    let prediction: RoboflowPrediction
}

private enum RoboflowPredictionKind {
    case digit(String)
    case label(RoboflowReadingLabel)

    nonisolated init?(classText: String) {
        let normalized = classText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.count == 1, normalized.allSatisfy(\.isNumber) {
            self = .digit(normalized)
            return
        }

        if let label = RoboflowReadingLabel(rawValue: normalized) {
            self = .label(label)
            return
        }

        return nil
    }

    nonisolated var digit: String? {
        if case let .digit(digit) = self { return digit }
        return nil
    }

    nonisolated var label: RoboflowReadingLabel? {
        if case let .label(label) = self { return label }
        return nil
    }
}

private enum RoboflowReadingLabel: String {
    case systolic = "sys"
    case diastolic = "dia"
    case pulse = "pul"
}

enum RoboflowVisionError: Error {
    case invalidResponse
    case api(String)
}

private extension UIImage {
    func resizedForRoboflowUpload(maxPixelSize: CGFloat = 1600) -> UIImage {
        let largestSide = max(size.width, size.height)
        guard largestSide > maxPixelSize else { return self }

        let scale = maxPixelSize / largestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1

        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
