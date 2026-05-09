// MARK: Models/BloodPressureReading.swift

import Foundation
import FoundationModels

/// A structured reading from a blood pressure monitor.
/// Used with Foundation Models to enable structured output parsing.
@Generable
struct BloodPressureReading: Codable {
    @Guide(description: "Systolic blood pressure in mmHg as an integer")
    let systolic: Int

    @Guide(description: "Diastolic blood pressure in mmHg as an integer")
    let diastolic: Int

    @Guide(description: "Pulse in beats per minute as an integer. Null if not present.")
    let pulse: Int?
}
