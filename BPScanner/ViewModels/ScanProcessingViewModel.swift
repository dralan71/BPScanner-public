import Combine
import Foundation
import UIKit

@MainActor
final class ScanProcessingViewModel: ObservableObject {
    @Published var isProcessing = true
    @Published var errorMessage: String?

    private let interpreter: any ScanInterpreting
    private var hasStartedProcessing = false

    init(interpreter: any ScanInterpreting = ScanInterpreter()) {
        self.interpreter = interpreter
    }

    func processIfNeeded(image: UIImage) async -> BloodPressureReading? {
        guard !hasStartedProcessing else { return nil }
        hasStartedProcessing = true

        isProcessing = true
        errorMessage = nil

        do {
            let reading = try await interpreter.interpret(image: image)
            return reading
        } catch {
            isProcessing = false
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
