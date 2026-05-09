// MARK: Scanning/GeminiVisionService.swift

import Foundation
import UIKit

actor GeminiVisionService {
    private let session: URLSession = .shared
    private let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!

    func extractReading(from image: UIImage) async throws -> GeminiVisionResult? {
        guard let apiKey = loadAPIKey(),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let uploadImage = image.resizedForGeminiUpload()
        guard let imageData = uploadImage.jpegData(compressionQuality: 0.75) else {
            return nil
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(makeRequestBody(for: imageData))

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiVisionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data)
            throw GeminiVisionError.api(apiError?.error.message ?? "HTTP \(httpResponse.statusCode)")
        }

        let payload = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
        guard let rawText = payload.candidates?.first?.content.parts.compactMap(\.text).joined(separator: "\n"),
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if let jsonText = extractJSONObject(from: rawText) {
            do {
                return try JSONDecoder().decode(GeminiVisionResult.self, from: Data(jsonText.utf8))
            } catch {
                if let recovered = recoverReading(from: jsonText) {
                    return recovered
                }
                throw error
            }
        }

        if let recovered = recoverReading(from: rawText) {
            return recovered
        }

        throw GeminiVisionError.invalidJSON(rawText)
    }

    private func makeRequestBody(for imageData: Data) -> GeminiGenerateContentRequest {
        GeminiGenerateContentRequest(
            contents: [
                .init(parts: [
                    .init(text: """
                    Read the blood pressure monitor screen in this photo.
                    Focus only on the LCD display digits.
                    Ignore the monitor casing text, labels like SYS/DIA/PUL, time, branding, and warning text.
                    Do not guess missing digits.
                    If the reading is unclear, return low confidence.
                    """),
                    .init(inlineData: .init(mimeType: "image/jpeg", data: imageData.base64EncodedString()))
                ])
            ],
            generationConfig: .init(
                temperature: 0.1,
                topP: 1,
                maxOutputTokens: 1024,
                responseMimeType: "application/json",
                responseSchema: .object(
                    properties: [
                        "systolic": .integer(description: "Systolic blood pressure value in mmHg."),
                        "diastolic": .integer(description: "Diastolic blood pressure value in mmHg."),
                        "pulse": .integer(description: "Pulse value in bpm. Use 0 if not clearly visible."),
                        "pulseVisible": .boolean(description: "True if pulse is clearly visible on the display."),
                        "confidence": .number(description: "Confidence from 0.0 to 1.0."),
                        "reason": .string(description: "Short explanation of what was read or why the image is unclear.")
                    ],
                    required: ["systolic", "diastolic", "pulse", "pulseVisible", "confidence", "reason"]
                )
            )
        )
    }

    private func loadAPIKey() -> String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        return plist["GEMINI_API_KEY"] as? String
    }

    private func extractJSONObject(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }

        if let fencedRange = trimmed.range(of: #"```(?:json)?\s*([\s\S]*?)\s*```"#, options: .regularExpression) {
            let fenced = String(trimmed[fencedRange])
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if fenced.hasPrefix("{"), fenced.hasSuffix("}") {
                return fenced
            }
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            return nil
        }

        return String(trimmed[start...end])
    }

    private func recoverReading(from text: String) -> GeminiVisionResult? {
        guard let systolic = integerValue(for: "systolic", in: text),
              let diastolic = integerValue(for: "diastolic", in: text) else {
            return nil
        }

        let pulse = integerValue(for: "pulse", in: text) ?? 0
        let pulseVisible = booleanValue(for: "pulseVisible", in: text) ?? (pulse > 0)
        let confidence = doubleValue(for: "confidence", in: text) ?? 0.75
        let reason = stringValue(for: "reason", in: text) ?? "Recovered from partial Gemini response."

        return GeminiVisionResult(
            systolic: systolic,
            diastolic: diastolic,
            pulse: pulse,
            pulseVisible: pulseVisible,
            confidence: confidence,
            reason: reason
        )
    }

    private func integerValue(for key: String, in text: String) -> Int? {
        let pattern = #""# + key + #""\s*:\s*(\d+)"#
        guard let match = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }

        let matchedText = String(text[match])
        guard let value = matchedText.split(separator: ":").last else {
            return nil
        }

        return Int(String(value).trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\r\t")))
    }

    private func doubleValue(for key: String, in text: String) -> Double? {
        let pattern = #""# + key + #""\s*:\s*(\d+(?:\.\d+)?)"#
        guard let match = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }

        let matchedText = String(text[match])
        guard let value = matchedText.split(separator: ":").last else {
            return nil
        }

        return Double(String(value).trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\r\t")))
    }

    private func booleanValue(for key: String, in text: String) -> Bool? {
        let pattern = #""# + key + #""\s*:\s*(true|false)"#
        guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }

        let matchedText = String(text[match]).lowercased()
        if matchedText.contains("true") {
            return true
        }
        if matchedText.contains("false") {
            return false
        }
        return nil
    }

    private func stringValue(for key: String, in text: String) -> String? {
        let pattern = #""# + key + #""\s*:\s*"([^"]*)""#
        guard let match = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }

        let matchedText = String(text[match])
        guard let colon = matchedText.firstIndex(of: ":") else {
            return nil
        }

        return String(matchedText[matchedText.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

private extension UIImage {
    func resizedForGeminiUpload(maxPixelSize: CGFloat = 1600) -> UIImage {
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

struct GeminiVisionResult: Decodable {
    let systolic: Int
    let diastolic: Int
    let pulse: Int
    let pulseVisible: Bool
    let confidence: Double
    let reason: String

    var reading: BloodPressureReading {
        BloodPressureReading(
            systolic: systolic,
            diastolic: diastolic,
            pulse: pulseVisible ? pulse : nil
        )
    }
}

private struct GeminiGenerateContentRequest: Encodable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig
}

private struct GeminiContent: Encodable {
    let parts: [GeminiPart]
}

private struct GeminiPart: Encodable {
    let text: String?
    let inlineData: GeminiInlineData?

    init(text: String) {
        self.text = text
        self.inlineData = nil
    }

    init(inlineData: GeminiInlineData) {
        self.text = nil
        self.inlineData = inlineData
    }

    enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
    }
}

private struct GeminiInlineData: Encodable {
    let mimeType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
    }
}

private struct GeminiGenerationConfig: Encodable {
    let temperature: Double
    let topP: Double
    let maxOutputTokens: Int
    let responseMimeType: String
    let responseSchema: GeminiSchema
}

private struct GeminiSchema: Encodable {
    let type: String
    let properties: [String: GeminiSchema]?
    let required: [String]?
    let description: String?

    nonisolated static func object(properties: [String: GeminiSchema], required: [String]) -> GeminiSchema {
        GeminiSchema(type: "object", properties: properties, required: required, description: nil)
    }

    nonisolated static func integer(description: String) -> GeminiSchema {
        GeminiSchema(type: "integer", properties: nil, required: nil, description: description)
    }

    nonisolated static func number(description: String) -> GeminiSchema {
        GeminiSchema(type: "number", properties: nil, required: nil, description: description)
    }

    nonisolated static func boolean(description: String) -> GeminiSchema {
        GeminiSchema(type: "boolean", properties: nil, required: nil, description: description)
    }

    nonisolated static func string(description: String) -> GeminiSchema {
        GeminiSchema(type: "string", properties: nil, required: nil, description: description)
    }
}

private struct GeminiGenerateContentResponse: Decodable {
    let candidates: [GeminiCandidate]?
}

private struct GeminiCandidate: Decodable {
    let content: GeminiCandidateContent
}

private struct GeminiCandidateContent: Decodable {
    let parts: [GeminiCandidatePart]
}

private struct GeminiCandidatePart: Decodable {
    let text: String?
}

private struct GeminiErrorEnvelope: Decodable {
    let error: GeminiAPIError
}

private struct GeminiAPIError: Decodable {
    let message: String
}

enum GeminiVisionError: Error {
    case invalidResponse
    case invalidJSON(String)
    case api(String)
}
