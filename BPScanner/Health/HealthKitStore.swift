import Foundation
import HealthKit

/// Injectable boundary for testing identity and recovery without changing real health data.
nonisolated protocol HealthKitStoring: Sendable {
    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws
    func samples(of type: HKSampleType, matching filter: HealthKitSampleFilter) async throws -> [HKSample]
    func save(_ samples: [HKSample]) async throws
    func delete(_ samples: [HKSample]) async throws
    func owns(_ sample: HKSample) async -> Bool
}

actor LiveHealthKitStore: HealthKitStoring {
    private let store = HKHealthStore()

    init() {}

    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws {
        try await store.requestAuthorization(toShare: toShare, read: read)
    }

    func save(_ samples: [HKSample]) async throws { try await store.save(samples) }
    func delete(_ samples: [HKSample]) async throws { try await store.delete(samples) }
    func owns(_ sample: HKSample) async -> Bool {
        sample.sourceRevision.source == HKSource.default()
    }

    func samples(of type: HKSampleType, matching filter: HealthKitSampleFilter) async throws -> [HKSample] {
        let predicate: NSPredicate
        switch filter {
        case let .interval(start, end):
            predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        case let .uuid(id):
            predicate = HKQuery.predicateForObject(with: id)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }
}

nonisolated enum HealthKitSampleFilter: Sendable {
    case interval(Date, Date)
    case uuid(UUID)
}
