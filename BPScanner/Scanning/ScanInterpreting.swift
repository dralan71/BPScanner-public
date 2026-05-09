import UIKit

protocol ScanInterpreting: Sendable {
    func interpret(image: UIImage) async throws -> BloodPressureReading
}
