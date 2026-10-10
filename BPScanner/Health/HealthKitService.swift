// MARK: Health/HealthKitService.swift

import Foundation
import HealthKit

/// Service for managing all HealthKit operations.
/// Handles authorization, reading historical BP data, and saving new readings.
actor HealthKitService {
    static let shared = HealthKitService()

    private let store: any HealthKitStoring
    private var mutationsInProgress: Set<UUID> = []
    static let readingLinkKey = "com.dralan71.BPScanner.readingID"
    static let pulseIDKey = "com.dralan71.BPScanner.pulseID"

    init(store: any HealthKitStoring = LiveHealthKitStore()) {
        self.store = store
    }

    /// Request HealthKit permissions for reading and writing blood pressure and heart rate.
    /// Should be called once on app launch.
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.healthDataUnavailable
        }

        let typesToWrite: Set<HKSampleType> = [
            HKSampleType.quantityType(forIdentifier: .bloodPressureSystolic)!,
            HKSampleType.quantityType(forIdentifier: .bloodPressureDiastolic)!,
            HKSampleType.quantityType(forIdentifier: .heartRate)!,
        ]

        let typesToRead: Set<HKObjectType> = [
            HKSampleType.quantityType(forIdentifier: .bloodPressureSystolic)!,
            HKSampleType.quantityType(forIdentifier: .bloodPressureDiastolic)!,
            HKSampleType.quantityType(forIdentifier: .heartRate)!,
        ]

        try await store.requestAuthorization(toShare: typesToWrite, read: typesToRead)
    }

    /// Save a blood pressure reading to HealthKit.
    /// Saves systolic and diastolic as an HKCorrelation, and pulse as a separate HKQuantitySample.
    func saveReading(
        systolic: Int,
        diastolic: Int,
        pulse: Int?,
        at timestamp: Date
    ) async throws {
        try await store.save(makeSamples(systolic: systolic, diastolic: diastolic, pulse: pulse, at: timestamp))
    }

    private func makeSamples(systolic: Int, diastolic: Int, pulse: Int?, at timestamp: Date) -> [HKSample] {
        let metadata = [Self.readingLinkKey: UUID().uuidString]
        let systolicSample = HKQuantitySample(
            type: HKSampleType.quantityType(forIdentifier: .bloodPressureSystolic)!,
            quantity: HKQuantity(unit: HKUnit.millimeterOfMercury(), doubleValue: Double(systolic)),
            start: timestamp,
            end: timestamp,
            metadata: metadata
        )

        let diastolicSample = HKQuantitySample(
            type: HKSampleType.quantityType(forIdentifier: .bloodPressureDiastolic)!,
            quantity: HKQuantity(unit: HKUnit.millimeterOfMercury(), doubleValue: Double(diastolic)),
            start: timestamp,
            end: timestamp,
            metadata: metadata
        )

        let pulseSample = pulse.map { value in
            HKQuantitySample(
                type: HKSampleType.quantityType(forIdentifier: .heartRate)!,
                quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: HKUnit.minute()), doubleValue: Double(value)),
                start: timestamp,
                end: timestamp,
                metadata: metadata
            )
        }
        var correlationMetadata = metadata
        if let pulseSample { correlationMetadata[Self.pulseIDKey] = pulseSample.uuid.uuidString }
        let bpCorrelation = HKCorrelation(
            type: HKCorrelationType(.bloodPressure),
            start: timestamp,
            end: timestamp,
            objects: [systolicSample, diastolicSample],
            metadata: correlationMetadata
        )
        var samplesToSave: [HKSample] = [bpCorrelation]
        if let pulseSample { samplesToSave.append(pulseSample) }

        return samplesToSave
    }

    func updateReading(
        _ originalReading: StoredBloodPressureReading,
        systolic: Int,
        diastolic: Int,
        pulse: Int?,
        at timestamp: Date
    ) async throws {
        try beginMutation(originalReading.id)
        defer { mutationsInProgress.remove(originalReading.id) }
        let originalSamples = try await samplesMatching(originalReading)
        let replacement = makeSamples(systolic: systolic, diastolic: diastolic, pulse: pulse, at: timestamp)
        try await store.save(replacement)
        do {
            try await store.delete(originalSamples)
        } catch {
            // HealthKit does not document batch deletion as atomic. Only roll back
            // the replacement after confirming every original sample still exists.
            do {
                for sample in originalSamples {
                    let remaining = try await store.samples(of: sample.sampleType, matching: .uuid(sample.uuid))
                    guard remaining.contains(where: { $0.uuid == sample.uuid }) else {
                        throw HealthKitError.updateRecoveryFailed
                    }
                }
            } catch {
                throw HealthKitError.updateRecoveryFailed
            }
            do {
                try await store.delete(deletionSamples(for: replacement))
            } catch {
                throw HealthKitError.updateRecoveryFailed
            }
            throw error
        }
    }

    /// Retrieve blood pressure and heart rate readings for a given time range.
    /// Preserves correlation UUIDs; legacy pulse proximity is used only for display.
    func fetchReadings(startDate: Date, endDate: Date) async throws -> [StoredBloodPressureReading] {
        let bpType = HKCorrelationType(.bloodPressure)
        let filter = HealthKitSampleFilter.interval(startDate, endDate)

        let bpReadings = try await store.samples(of: bpType, matching: filter)

        // Fetch heart rate data separately
        let heartRateType = HKSampleType.quantityType(forIdentifier: .heartRate)!
        let pulseReadings = try await store.samples(of: heartRateType, matching: filter)
            .compactMap { $0 as? HKQuantitySample }

        // Extract systolic and diastolic from correlations
        var result: [StoredBloodPressureReading] = []
        for sample in bpReadings {
            guard let correlation = sample as? HKCorrelation else { continue }

            var systolic: Int?
            var diastolic: Int?

            for obj in correlation.objects {
                guard let quantitySample = obj as? HKQuantitySample else { continue }

                if quantitySample.quantityType.identifier == HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue {
                    systolic = Int(quantitySample.quantity.doubleValue(for: HKUnit.millimeterOfMercury()))
                } else if quantitySample.quantityType.identifier == HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue {
                    diastolic = Int(quantitySample.quantity.doubleValue(for: HKUnit.millimeterOfMercury()))
                }
            }

            if let systolic = systolic, let diastolic = diastolic {
                let link = correlation.metadata?[Self.readingLinkKey] as? String
                let pulseID = (correlation.metadata?[Self.pulseIDKey] as? String).flatMap(UUID.init(uuidString:))
                let linkedPulse = pulseReadings.first { pulse in
                    pulse.uuid == pulseID && link != nil && pulse.metadata?[Self.readingLinkKey] as? String == link
                }
                // Legacy samples have no explicit link. Proximity is display-only.
                let pulseSample = linkedPulse ?? (link == nil ? pulseReadings
                    .filter { abs($0.startDate.timeIntervalSince(sample.startDate)) <= 2 }
                    .min { abs($0.startDate.timeIntervalSince(sample.startDate)) < abs($1.startDate.timeIntervalSince(sample.startDate)) } : nil)
                let pulse = pulseSample.map {
                    Int($0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute())))
                }
                result.append(
                    StoredBloodPressureReading(
                        id: correlation.uuid,
                        systolic: systolic,
                        diastolic: diastolic,
                        pulse: pulse,
                        timestamp: sample.startDate
                    )
                )
            }
        }

        return result
    }

    func deleteReading(_ reading: StoredBloodPressureReading) async throws {
        try beginMutation(reading.id)
        defer { mutationsInProgress.remove(reading.id) }
        let samples = try await samplesMatching(reading)
        try await store.delete(samples)
    }

    private func beginMutation(_ id: UUID) throws {
        guard mutationsInProgress.insert(id).inserted else {
            throw HealthKitError.mutationInProgress
        }
    }

    private func samplesMatching(_ reading: StoredBloodPressureReading) async throws -> [HKSample] {
        let matches = try await store.samples(
            of: HKCorrelationType(.bloodPressure),
            matching: .uuid(reading.id)
        )
        guard let correlation = matches.first(where: { $0.uuid == reading.id }) as? HKCorrelation else {
            throw HealthKitError.readingNotFound
        }
        guard await store.owns(correlation) else {
            throw HealthKitError.readingNotOwned
        }
        var result: [HKSample] = [correlation]
        for sample in correlation.objects {
            guard await store.owns(sample) else { throw HealthKitError.readingNotOwned }
            result.append(sample)
        }
        if let link = correlation.metadata?[Self.readingLinkKey] as? String,
           let pulseIDText = correlation.metadata?[Self.pulseIDKey] as? String,
           let pulseID = UUID(uuidString: pulseIDText) {
            let pulses = try await store.samples(
                of: HKSampleType.quantityType(forIdentifier: .heartRate)!,
                matching: .uuid(pulseID)
            )
            for pulse in pulses where pulse.uuid == pulseID && pulse.metadata?[Self.readingLinkKey] as? String == link {
                if await store.owns(pulse) { result.append(pulse) }
            }
        }
        return result
    }

    private func deletionSamples(for samples: [HKSample]) -> [HKSample] {
        samples + samples.compactMap { $0 as? HKCorrelation }.flatMap { Array($0.objects) }
    }
}

extension HealthKitService: HealthKitServicing {}

nonisolated enum HealthKitError: LocalizedError {
    case healthDataUnavailable
    case readingNotFound
    case readingNotOwned
    case mutationInProgress
    case updateRecoveryFailed

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            String(localized: "HealthKit data is not available on this device.", bundle: .main)
        case .readingNotFound:
            String(localized: "This reading no longer exists in Apple Health. Refresh your readings and try again.", bundle: .main)
        case .readingNotOwned:
            String(localized: "This reading was saved by another app. Manage it in Apple Health.", bundle: .main)
        case .mutationInProgress:
            String(localized: "This reading is already being updated. Please wait.", bundle: .main)
        case .updateRecoveryFailed:
            String(localized: "The update could not be completed or rolled back. Check Apple Health for duplicate readings before retrying.", bundle: .main)
        }
    }
}
