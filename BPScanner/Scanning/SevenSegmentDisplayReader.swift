// MARK: Scanning/SevenSegmentDisplayReader.swift

import CoreGraphics
import Foundation
import UIKit

/// Reads large seven-segment LCD digits from a blood pressure monitor photo.
///
/// This intentionally does not use OCR. Vision's text recognizer is tuned for glyph
/// text, while monitor digits are often disconnected LCD segments.
struct SevenSegmentDisplayReader {
    private let maximumAnalysisWidth = 900
    private let minimumComponentAreaRatio = 0.00008
    private let minimumDigitHeightRatio = 0.045

    func extractReading(from image: UIImage) throws -> BloodPressureReading? {
        guard let bitmap = DisplayBitmap(image: image, maximumWidth: maximumAnalysisWidth) else {
            return nil
        }

        let crops = candidateCrops(for: bitmap.size)
        var bestCandidate: ReadingCandidate?

        for crop in crops {
            guard let candidate = read(in: crop.integral.clamped(to: bitmap.bounds), bitmap: bitmap) else {
                continue
            }

            NSLog(
                "[SEVEN_SEGMENT] Candidate score %.2f crop=%@ rows=%@",
                candidate.score,
                NSCoder.string(for: crop),
                candidate.rows.map(\.debugDescription).joined(separator: " | ")
            )

            if bestCandidate == nil || candidate.score > bestCandidate!.score {
                bestCandidate = candidate
            }
        }

        guard let bestCandidate else {
            NSLog("[SEVEN_SEGMENT] No seven-segment candidate found")
            return nil
        }

        NSLog(
            "[SEVEN_SEGMENT] Selected SYS=%d DIA=%d PULSE=%d score=%.2f",
            bestCandidate.reading.systolic,
            bestCandidate.reading.diastolic,
            bestCandidate.reading.pulse ?? 0,
            bestCandidate.score
        )

        return bestCandidate.reading
    }

    private func read(in crop: CGRect, bitmap: DisplayBitmap) -> ReadingCandidate? {
        let binary = makeBinaryMask(for: crop, bitmap: bitmap)
        let bands = rowBands(in: binary)
        let rows = bands.compactMap { decodeRow($0, in: binary) }
            .filter { (2...3).contains(String($0.value).count) }
            .sorted { $0.frame.minY < $1.frame.minY }

        guard rows.count >= 2 else {
            return nil
        }

        return makeReadingCandidate(from: rows)
    }

    private func makeBinaryMask(for crop: CGRect, bitmap: DisplayBitmap) -> BinaryMask {
        let cropRect = crop.integral.clamped(to: bitmap.bounds)
        let luminances = bitmap.luminances(in: cropRect)
        let threshold = otsuThreshold(luminances)

        var pixels: [Bool] = []
        pixels.reserveCapacity(luminances.count)

        for luminance in luminances {
            pixels.append(luminance < threshold)
        }

        return BinaryMask(
            width: Int(cropRect.width),
            height: Int(cropRect.height),
            origin: CGPoint(x: cropRect.minX, y: cropRect.minY),
            pixels: pixels
        )
    }

    private func rowBands(in mask: BinaryMask) -> [CGRect] {
        let rowCounts = (0..<mask.height).map { y in
            var count = 0
            for x in 0..<mask.width where mask[x, y] {
                count += 1
            }
            return count
        }

        let minimumCount = max(8, Int(Double(mask.width) * 0.025))
        var bands: [ClosedRange<Int>] = []
        var start: Int?
        var quietRows = 0

        for (y, count) in rowCounts.enumerated() {
            if count >= minimumCount {
                if start == nil {
                    start = y
                }
                quietRows = 0
            } else if let bandStart = start {
                quietRows += 1
                if quietRows >= 3 {
                    bands.append(bandStart...max(bandStart, y - quietRows))
                    start = nil
                    quietRows = 0
                }
            }
        }

        if let bandStart = start {
            bands.append(bandStart...max(bandStart, mask.height - 1))
        }

        return bands
            .map { band in
                CGRect(
                    x: 0,
                    y: max(0, band.lowerBound - 3),
                    width: mask.width,
                    height: min(mask.height - max(0, band.lowerBound - 3), band.count + 6)
                )
            }
            .filter { $0.height >= CGFloat(mask.height) * minimumDigitHeightRatio }
    }

    private func decodeRow(_ rowFrame: CGRect, in mask: BinaryMask) -> RowCandidate? {
        let components = connectedComponents(in: rowFrame, mask: mask)
            .filter { component in
                let minArea = Double(mask.width * mask.height) * minimumComponentAreaRatio
                return Double(component.area) >= minArea && component.frame.height >= rowFrame.height * 0.35
            }

        guard !components.isEmpty else {
            return nil
        }

        let digitFrames = mergeDigitFrames(components.map(\.frame), rowFrame: rowFrame)
        let decoded = digitFrames.compactMap { frame -> DigitCandidate? in
            guard frame.height >= rowFrame.height * 0.4 else { return nil }
            return classifyDigit(in: frame.expandedBy(dx: 2, dy: 2).clamped(to: mask.bounds), mask: mask)
        }

        guard decoded.count >= 2, decoded.count <= 3 else {
            return nil
        }

        let text = decoded.map { String($0.value) }.joined()
        guard let value = Int(text), value >= 20 else {
            return nil
        }

        let confidence = decoded.map(\.confidence).reduce(0, +) / Double(decoded.count)
        guard confidence >= 0.48 else {
            return nil
        }

        let unionFrame = digitFrames.reduce(CGRect.null) { $0.union($1) }
        return RowCandidate(
            value: value,
            digits: decoded,
            confidence: confidence,
            frame: unionFrame.offsetBy(dx: mask.origin.x, dy: mask.origin.y)
        )
    }

    private func connectedComponents(in rowFrame: CGRect, mask: BinaryMask) -> [Component] {
        let bounds = rowFrame.integral.clamped(to: mask.bounds)
        var visited = Array(repeating: false, count: mask.width * mask.height)
        var components: [Component] = []
        let minX = Int(bounds.minX)
        let maxX = Int(bounds.maxX)
        let minY = Int(bounds.minY)
        let maxY = Int(bounds.maxY)

        for y in minY..<maxY {
            for x in minX..<maxX where mask[x, y] && !visited[mask.index(x, y)] {
                var stack = [(x, y)]
                visited[mask.index(x, y)] = true
                var area = 0
                var left = x
                var right = x
                var top = y
                var bottom = y

                while let (currentX, currentY) = stack.popLast() {
                    area += 1
                    left = min(left, currentX)
                    right = max(right, currentX)
                    top = min(top, currentY)
                    bottom = max(bottom, currentY)

                    for neighborY in max(minY, currentY - 1)...min(maxY - 1, currentY + 1) {
                        for neighborX in max(minX, currentX - 1)...min(maxX - 1, currentX + 1) {
                            let neighborIndex = mask.index(neighborX, neighborY)
                            if mask[neighborX, neighborY] && !visited[neighborIndex] {
                                visited[neighborIndex] = true
                                stack.append((neighborX, neighborY))
                            }
                        }
                    }
                }

                components.append(
                    Component(
                        frame: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1),
                        area: area
                    )
                )
            }
        }

        return components
    }

    private func mergeDigitFrames(_ frames: [CGRect], rowFrame: CGRect) -> [CGRect] {
        let sortedFrames = frames
            .filter { $0.width >= 3 && $0.height >= 8 }
            .sorted { $0.minX < $1.minX }

        var merged: [CGRect] = []
        let maximumGap = max(3, rowFrame.height * 0.12)

        for frame in sortedFrames {
            guard var last = merged.popLast() else {
                merged.append(frame)
                continue
            }

            let gap = frame.minX - last.maxX
            let similarHeight = min(frame.height, last.height) / max(frame.height, last.height) > 0.35

            if gap <= maximumGap && similarHeight {
                last = last.union(frame)
                merged.append(last)
            } else {
                merged.append(last)
                merged.append(frame)
            }
        }

        return merged
            .filter { frame in
                let aspect = frame.width / max(1, frame.height)
                return aspect >= 0.12 && aspect <= 0.85
            }
    }

    private func classifyDigit(in frame: CGRect, mask: BinaryMask) -> DigitCandidate? {
        let segments = Segment.allCases.map { occupancy(of: $0, in: frame, mask: mask) }
        let activeSegments = segments.map { $0 >= 0.22 }

        var bestValue: Int?
        var bestScore = Double.greatestFiniteMagnitude

        for (digit, pattern) in Segment.digitPatterns {
            var score = 0.0
            for index in Segment.allCases.indices {
                let expected = pattern[index]
                let occupancy = segments[index]
                score += expected ? max(0, 0.38 - occupancy) : max(0, occupancy - 0.16)
                if expected != activeSegments[index] {
                    score += 0.22
                }
            }

            if score < bestScore {
                bestScore = score
                bestValue = digit
            }
        }

        guard let bestValue else {
            return nil
        }

        let confidence = max(0, min(1, 1 - (bestScore / 2.1)))
        return DigitCandidate(value: bestValue, confidence: confidence, frame: frame)
    }

    private func occupancy(of segment: Segment, in frame: CGRect, mask: BinaryMask) -> Double {
        let region = segment.region(in: frame).integral.clamped(to: mask.bounds)
        guard region.width >= 1, region.height >= 1 else {
            return 0
        }

        var dark = 0
        let total = Int(region.width * region.height)

        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) where mask[x, y] {
                dark += 1
            }
        }

        return Double(dark) / Double(max(1, total))
    }

    private func makeReadingCandidate(from rows: [RowCandidate]) -> ReadingCandidate? {
        for systolicIndex in rows.indices {
            let systolic = rows[systolicIndex]
            guard (70...260).contains(systolic.value) else { continue }

            for diastolicIndex in rows.indices where diastolicIndex > systolicIndex {
                let diastolic = rows[diastolicIndex]
                guard (40...160).contains(diastolic.value), systolic.value > diastolic.value else {
                    continue
                }

                let pulse = rows.dropFirst(diastolicIndex + 1).first { (35...220).contains($0.value) }
                let reading = BloodPressureReading(
                    systolic: systolic.value,
                    diastolic: diastolic.value,
                    pulse: pulse?.value
                )
                let rowScore = systolic.confidence + diastolic.confidence + (pulse?.confidence ?? 0)
                let orderScore = 1.0 / Double(1 + systolicIndex + diastolicIndex)
                return ReadingCandidate(reading: reading, rows: rows, score: rowScore + orderScore)
            }
        }

        return nil
    }

    private func candidateCrops(for size: CGSize) -> [CGRect] {
        let width = size.width
        let height = size.height

        return [
            CGRect(x: 0, y: 0, width: width, height: height),
            CGRect(x: width * 0.06, y: height * 0.08, width: width * 0.88, height: height * 0.72),
            CGRect(x: width * 0.10, y: height * 0.10, width: width * 0.80, height: height * 0.68),
            CGRect(x: width * 0.14, y: height * 0.12, width: width * 0.72, height: height * 0.62),
            CGRect(x: width * 0.18, y: height * 0.08, width: width * 0.64, height: height * 0.76)
        ]
    }

    private func otsuThreshold(_ luminances: [UInt8]) -> UInt8 {
        var histogram = Array(repeating: 0, count: 256)
        luminances.forEach { histogram[Int($0)] += 1 }

        let total = luminances.count
        let sum = histogram.enumerated().reduce(0) { $0 + ($1.offset * $1.element) }
        var backgroundWeight = 0
        var backgroundSum = 0
        var bestVariance = 0.0
        var bestThreshold = 128

        for threshold in 0..<256 {
            backgroundWeight += histogram[threshold]
            if backgroundWeight == 0 { continue }

            let foregroundWeight = total - backgroundWeight
            if foregroundWeight == 0 { break }

            backgroundSum += threshold * histogram[threshold]
            let backgroundMean = Double(backgroundSum) / Double(backgroundWeight)
            let foregroundMean = Double(sum - backgroundSum) / Double(foregroundWeight)
            let variance = Double(backgroundWeight * foregroundWeight) * pow(backgroundMean - foregroundMean, 2)

            if variance > bestVariance {
                bestVariance = variance
                bestThreshold = threshold
            }
        }

        return UInt8(max(35, min(190, bestThreshold)))
    }
}

private struct DisplayBitmap {
    let width: Int
    let height: Int
    let data: [UInt8]

    var size: CGSize { CGSize(width: width, height: height) }
    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    init?(image: UIImage, maximumWidth: Int) {
        let scale = min(1, CGFloat(maximumWidth) / max(1, image.size.width))
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let width = max(1, Int(targetSize.width.rounded()))
        let height = max(1, Int(targetSize.height.rounded()))
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = Array(repeating: UInt8(0), count: height * bytesPerRow)

        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()

        self.width = width
        self.height = height
        self.data = data
    }

    func luminances(in rect: CGRect) -> [UInt8] {
        let crop = rect.integral.clamped(to: bounds)
        var values: [UInt8] = []
        values.reserveCapacity(Int(crop.width * crop.height))

        for y in Int(crop.minY)..<Int(crop.maxY) {
            for x in Int(crop.minX)..<Int(crop.maxX) {
                values.append(luminanceAt(x: x, y: y))
            }
        }

        return values
    }

    private func luminanceAt(x: Int, y: Int) -> UInt8 {
        let offset = ((y * width) + x) * 4
        let red = Double(data[offset])
        let green = Double(data[offset + 1])
        let blue = Double(data[offset + 2])
        return UInt8(max(0, min(255, (0.299 * red) + (0.587 * green) + (0.114 * blue))))
    }
}

private struct BinaryMask {
    let width: Int
    let height: Int
    let origin: CGPoint
    let pixels: [Bool]

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    subscript(x: Int, y: Int) -> Bool {
        pixels[index(x, y)]
    }

    func index(_ x: Int, _ y: Int) -> Int {
        (y * width) + x
    }
}

private struct Component {
    let frame: CGRect
    let area: Int
}

private struct DigitCandidate {
    let value: Int
    let confidence: Double
    let frame: CGRect
}

private struct RowCandidate {
    let value: Int
    let digits: [DigitCandidate]
    let confidence: Double
    let frame: CGRect

    var debugDescription: String {
        let digitScores = digits
            .map { "\($0.value):\(String(format: "%.2f", $0.confidence))" }
            .joined(separator: ",")
        return "\(value)[\(digitScores)]"
    }
}

private struct ReadingCandidate {
    let reading: BloodPressureReading
    let rows: [RowCandidate]
    let score: Double
}

private enum Segment: CaseIterable {
    case top
    case upperLeft
    case upperRight
    case middle
    case lowerLeft
    case lowerRight
    case bottom

    static let digitPatterns: [Int: [Bool]] = [
        0: [true, true, true, false, true, true, true],
        1: [false, false, true, false, false, true, false],
        2: [true, false, true, true, true, false, true],
        3: [true, false, true, true, false, true, true],
        4: [false, true, true, true, false, true, false],
        5: [true, true, false, true, false, true, true],
        6: [true, true, false, true, true, true, true],
        7: [true, false, true, false, false, true, false],
        8: [true, true, true, true, true, true, true],
        9: [true, true, true, true, false, true, true]
    ]

    func region(in frame: CGRect) -> CGRect {
        let x = frame.minX
        let y = frame.minY
        let width = frame.width
        let height = frame.height

        switch self {
        case .top:
            return CGRect(x: x + width * 0.24, y: y + height * 0.02, width: width * 0.52, height: height * 0.18)
        case .upperLeft:
            return CGRect(x: x + width * 0.02, y: y + height * 0.14, width: width * 0.28, height: height * 0.34)
        case .upperRight:
            return CGRect(x: x + width * 0.70, y: y + height * 0.14, width: width * 0.28, height: height * 0.34)
        case .middle:
            return CGRect(x: x + width * 0.22, y: y + height * 0.41, width: width * 0.56, height: height * 0.18)
        case .lowerLeft:
            return CGRect(x: x + width * 0.02, y: y + height * 0.52, width: width * 0.28, height: height * 0.34)
        case .lowerRight:
            return CGRect(x: x + width * 0.70, y: y + height * 0.52, width: width * 0.28, height: height * 0.34)
        case .bottom:
            return CGRect(x: x + width * 0.24, y: y + height * 0.80, width: width * 0.52, height: height * 0.18)
        }
    }
}

private extension CGRect {
    func clamped(to bounds: CGRect) -> CGRect {
        let minX = max(bounds.minX, self.minX)
        let minY = max(bounds.minY, self.minY)
        let maxX = min(bounds.maxX, self.maxX)
        let maxY = min(bounds.maxY, self.maxY)

        guard maxX > minX, maxY > minY else {
            return .zero
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func expandedBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        insetBy(dx: -dx, dy: -dy)
    }
}
