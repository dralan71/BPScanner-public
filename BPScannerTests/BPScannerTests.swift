import Foundation
import Testing
@testable import BPScanner

@MainActor
struct BPScannerTests {

    @Test func reviewViewModelRejectsIncompleteReading() {
        let viewModel = ReviewViewModel(
            systolic: 120,
            diastolic: 80,
            pulse: 70,
            timestamp: Date(timeIntervalSince1970: 0)
        )

        viewModel.systolic = ""

        #expect(viewModel.isValid == false)
    }

    @Test func manualEntryViewModelAcceptsPositiveValues() {
        let viewModel = ManualEntryViewModel(defaultDate: Date(timeIntervalSince1970: 0))

        viewModel.systolic = "118"
        viewModel.diastolic = "76"

        #expect(viewModel.isValid)
    }

    @Test func timeRangeMonthCoversAtLeastCurrentMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_746_230_400) // 2025-05-01 00:00:00 UTC

        let range = MainViewModel.TimeRange.month.dateRange(now: now, calendar: calendar)
        let dayCount = calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 0

        #expect(dayCount >= 30)
    }

    @Test func reviewShareSummaryIncludesPulseWhenAvailable() {
        let timestamp = Date(timeIntervalSince1970: 0)
        let viewModel = ReviewViewModel(
            systolic: 121,
            diastolic: 79,
            pulse: 72,
            timestamp: timestamp
        )

        let summary = viewModel.shareSummary(systolic: 121, diastolic: 79, pulse: 72)

        #expect(summary.contains("121/79"))
        #expect(summary.contains("72"))
    }

    @Test func roboflowParserUsesDetectedLabelsToAssignRows() {
        let predictions = [
            prediction("dia", x: 40, y: 100),
            prediction("7", x: 120, y: 100),
            prediction("8", x: 152, y: 100),
            prediction("sys", x: 40, y: 160),
            prediction("1", x: 120, y: 160),
            prediction("2", x: 152, y: 160),
            prediction("1", x: 184, y: 160),
            prediction("pul", x: 40, y: 220),
            prediction("6", x: 120, y: 220),
            prediction("9", x: 152, y: 220)
        ]

        let reading = RoboflowVisionService.makeReadingForTesting(fromRawPredictions: predictions)

        #expect(reading?.systolic == 121)
        #expect(reading?.diastolic == 78)
        #expect(reading?.pulse == 69)
    }

    @Test func roboflowParserFallsBackToVerticalRowsWithoutLabels() {
        let predictions = [
            prediction("1", x: 120, y: 100),
            prediction("1", x: 152, y: 100),
            prediction("8", x: 184, y: 100),
            prediction("7", x: 120, y: 160),
            prediction("6", x: 152, y: 160),
            prediction("7", x: 120, y: 220),
            prediction("1", x: 152, y: 220)
        ]

        let reading = RoboflowVisionService.makeReadingForTesting(fromRawPredictions: predictions)

        #expect(reading?.systolic == 118)
        #expect(reading?.diastolic == 76)
        #expect(reading?.pulse == 71)
    }

    @Test func roboflowParserHandlesNestedResponseShapeAndNoisyPulseRow() {
        let rawResponse: Any = [
            [
                "predictions": [
                    "image": [
                        "width": 810,
                        "height": 1080
                    ],
                    "predictions": [
                        prediction("SYS", x: 503.5, y: 432.5, confidence: 0.857),
                        prediction("DIA", x: 506.5, y: 506, confidence: 0.844),
                        prediction("PUL", x: 510, y: 564, confidence: 0.840),
                        prediction("1", x: 374.5, y: 445, confidence: 0.895, width: 19, height: 70),
                        prediction("2", x: 400, y: 444, confidence: 0.653, width: 32, height: 76),
                        prediction("9", x: 440.5, y: 441.5, confidence: 0.838, width: 39, height: 75),
                        prediction("8", x: 401, y: 515.5, confidence: 0.876, width: 36, height: 73),
                        prediction("0", x: 441.5, y: 515, confidence: 0.898, width: 37, height: 74),
                        prediction("2", x: 329.5, y: 565, confidence: 0.530, width: 11, height: 20),
                        prediction("0", x: 352.5, y: 565, confidence: 0.530, width: 13, height: 20),
                        prediction("1", x: 364.5, y: 565, confidence: 0.391, width: 7, height: 18),
                        prediction("1", x: 408, y: 579, confidence: 0.573, width: 10, height: 30),
                        prediction("0", x: 427, y: 573.5, confidence: 0.606, width: 22, height: 41),
                        prediction("6", x: 451, y: 572, confidence: 0.935, width: 24, height: 44)
                    ]
                ]
            ]
        ]

        let reading = RoboflowVisionService.makeReadingForTesting(fromRawResponse: rawResponse)

        #expect(reading?.systolic == 129)
        #expect(reading?.diastolic == 80)
        #expect(reading?.pulse == 106)
    }

    private func prediction(
        _ label: String,
        x: Double,
        y: Double,
        confidence: Double = 0.92,
        width: Double? = nil,
        height: Double? = nil
    ) -> [String: Any] {
        [
            "class": label,
            "confidence": confidence,
            "x": x,
            "y": y,
            "width": width ?? (label.count == 1 ? 24 : 44),
            "height": height ?? 36
        ]
    }
}
