import Combine
import Foundation

@MainActor
final class ReviewViewModel: ObservableObject {
    enum EntryField: Hashable {
        case systolic
        case diastolic
        case pulse
    }

    @Published var systolic: String
    @Published var diastolic: String
    @Published var pulse: String
    @Published var isSaving = false
    @Published var isShowingShareSheet = false
    @Published var isShowingDismissAlert = false
    @Published var shareItems: [Any] = []

    let timestamp: Date
    private let originalSystolic: String
    private let originalDiastolic: String
    private let originalPulse: String

    init(systolic: Int, diastolic: Int, pulse: Int?, timestamp: Date) {
        let systolicText = String(systolic)
        let diastolicText = String(diastolic)
        let pulseText = pulse.map(String.init) ?? ""

        self.systolic = systolicText
        self.diastolic = diastolicText
        self.pulse = pulseText
        self.timestamp = timestamp
        self.originalSystolic = systolicText
        self.originalDiastolic = diastolicText
        self.originalPulse = pulseText
    }

    var isValid: Bool {
        guard let sys = Int(systolic), let dia = Int(diastolic) else {
            return false
        }

        return sys > 0 && dia > 0
    }

    var hasChanges: Bool {
        systolic != originalSystolic
            || diastolic != originalDiastolic
            || pulse != originalPulse
    }

    var showSystolicWarning: Bool {
        guard let sys = Int(systolic) else { return false }
        return sys < 90 || sys > 180
    }

    var showDiastolicWarning: Bool {
        guard let dia = Int(diastolic) else { return false }
        return dia < 50 || dia > 120
    }

    var formattedDate: String {
        timestamp.formatted(date: .abbreviated, time: .shortened)
    }

    func save(
        shareAfterSavingReading: Bool,
        onSave: @escaping (Int, Int, Int?, Date) async throws -> Void
    ) async -> Bool {
        guard !isSaving,
              let sys = Int(systolic),
              let dia = Int(diastolic) else {
            return false
        }

        let pulseValue = Int(pulse)
        isSaving = true

        do {
            try await onSave(sys, dia, pulseValue, timestamp)
            isSaving = false

            guard shareAfterSavingReading else {
                return true
            }

            shareItems = [shareSummary(systolic: sys, diastolic: dia, pulse: pulseValue)]
            isShowingShareSheet = true
            return false
        } catch {
            isSaving = false
            return false
        }
    }

    func shareSummary(systolic: Int, diastolic: Int, pulse: Int?) -> String {
        var summary = String(
            localized: "Blood pressure reading: \(systolic)/\(diastolic) mmHg",
            bundle: .main
        )

        if let pulse {
            summary += String(localized: ", pulse \(pulse) bpm", bundle: .main)
        }

        summary += String(localized: ", recorded \(formattedDate).", bundle: .main)
        return summary
    }
}
