// MARK: Scanning/OCRService.swift

import Foundation
import UIKit
@preconcurrency import Vision

/// Service for performing OCR using Apple's Vision framework.
/// Extracts text from blood pressure monitor images.
actor OCRService {
    /// Recognize text in an image using Vision's text recognition.
    /// Focuses on regions where blood pressure monitor numeric displays typically appear.
    func recognizeText(from image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw OCRError.invalidImage
        }

        // Try multiple regions to find the numeric display
        // Blood pressure monitors typically show large numbers in the center/upper portion
        let regions = [
            CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.4),  // Upper portion (primary)
            CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.6),  // Top half
            CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0),  // Full image (fallback)
        ]
        
        for regionRect in regions {
            print("[DEBUG OCR] Trying region: \(regionRect)")
            
            if let result = try await recognizeInRegion(cgImage, region: regionRect) {
                let cleanedText = extractNumbers(from: result)
                
                // If we found numbers, return this result
                if !cleanedText.isEmpty && cleanedText.contains(where: { $0.isNumber }) {
                    print("[DEBUG OCR] Found numbers in region: \(regionRect)")
                    return result
                }
            }
        }
        
        // Last resort: full image with all text
        return try await recognizeFullImage(cgImage)
    }
    
    private func recognizeInRegion(_ cgImage: CGImage, region: CGRect) async throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.regionOfInterest = region
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                    
                    let recognizedStrings = request.results?
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n") ?? ""
                    
                    continuation.resume(returning: recognizedStrings.isEmpty ? nil : recognizedStrings)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func recognizeFullImage(_ cgImage: CGImage) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                    
                    let recognizedStrings = request.results?
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n") ?? ""
                    
                    continuation.resume(returning: recognizedStrings)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Extract and clean numeric values from OCR text
    private func extractNumbers(from text: String) -> String {
        // Keep numbers, slashes, and basic formatting
        let cleaned = text.filter { $0.isNumber || $0 == "/" || $0 == " " || $0 == "\n" }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}

enum OCRError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return String(localized: "Failed to process the image.", bundle: .main)
        }
    }
}
