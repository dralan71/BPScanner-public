import Combine
import Foundation

@MainActor
final class ManualEntryViewModel: ObservableObject {
    enum EntryField: Hashable {
        case systolic
        case diastolic
        case pulse
    }

    @Published var systolic = ""
    @Published var diastolic = ""
    @Published var pulse = ""
    @Published var selectedDate: Date
    @Published var isSaving = false

    init(defaultDate: Date) {
        self.selectedDate = defaultDate
    }

    var isValid: Bool {
        guard let sys = Int(systolic), let dia = Int(diastolic) else {
            return false
        }

        return sys > 0 && dia > 0
    }

    func save(
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
            try await onSave(sys, dia, pulseValue, selectedDate)
            isSaving = false
            return true
        } catch {
            isSaving = false
            return false
        }
    }
}
