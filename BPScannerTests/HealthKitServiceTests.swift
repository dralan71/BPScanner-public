import Foundation
import HealthKit
import Testing
@testable import BPScanner

@MainActor
struct HealthKitServiceTests {
    @Test func identicalReadingsKeepDistinctIDsAndDeleteOnlySelectedReading() async throws {
        let store = TestHealthKitStore()
        let service = HealthKitService(store: store)
        try await save(service)
        try await save(service)
        let readings = try await fetch(service)
        #expect(readings.count == 2)
        #expect(Set(readings.map(\.id)).count == 2)
        try await service.deleteReading(readings[0])
        let remaining = try await fetch(service)
        #expect(remaining.map(\.id) == [readings[1].id])
        #expect(await store.count(of: .heartRate) == 1)
        #expect(await store.count(of: .bloodPressureSystolic) == 1)
        #expect(await store.count(of: .bloodPressureDiastolic) == 1)
    }

    @Test func updateOnlyReplacesSelectedDuplicate() async throws {
        let store = TestHealthKitStore()
        let service = HealthKitService(store: store)
        try await save(service)
        try await save(service)
        let readings = try await fetch(service)
        try await service.updateReading(readings[0], systolic: 130, diastolic: 85, pulse: 75, at: timestamp)
        let updated = try await fetch(service)
        #expect(updated.count == 2)
        #expect(updated.contains { $0.id == readings[1].id && $0.systolic == 120 && $0.pulse == 70 })
        #expect(updated.contains { $0.id != readings[0].id && $0.systolic == 130 && $0.pulse == 75 })
        #expect(await store.count(of: .heartRate) == 2)
    }

    @Test func failedReplacementSaveLeavesOriginalUntouched() async throws {
        let store = TestHealthKitStore()
        let service = HealthKitService(store: store)
        try await save(service)
        let original = try #require(try await fetch(service).first)
        await store.failNextSave()
        await #expect(throws: TestStoreError.self) {
            try await service.updateReading(original, systolic: 130, diastolic: 85, pulse: 75, at: timestamp)
        }
        #expect(try await fetch(service) == [original])
        #expect(await store.deleteCalls == 0)
        // The mutation guard must be released on failure, allowing retry.
        try await service.updateReading(original, systolic: 130, diastolic: 85, pulse: nil, at: timestamp)
        #expect(await store.count(of: .heartRate) == 0)
    }

    @Test func failedOriginalDeleteRollsBackReplacementIncludingConstituents() async throws {
        let store = TestHealthKitStore()
        let service = HealthKitService(store: store)
        try await save(service)
        let original = try #require(try await fetch(service).first)
        await store.failDeletes(1)
        await #expect(throws: TestStoreError.self) {
            try await service.updateReading(original, systolic: 130, diastolic: 85, pulse: 75, at: timestamp)
        }
        #expect(try await fetch(service) == [original])
        #expect(await store.count(of: .heartRate) == 1)
        #expect(await store.count(of: .bloodPressureSystolic) == 1)
        #expect(await store.count(of: .bloodPressureDiastolic) == 1)
    }

    @Test func rollbackFailureReportsRecoveryProblem() async throws {
        let store = TestHealthKitStore()
        let service = HealthKitService(store: store)
        try await save(service)
        let original = try #require(try await fetch(service).first)
        await store.failDeletes(2)
        do {
            try await service.updateReading(original, systolic: 130, diastolic: 85, pulse: 75, at: timestamp)
            Issue.record("Expected recovery failure")
        } catch HealthKitError.updateRecoveryFailed {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(try await fetch(service).count == 2)
        #expect(try await fetch(service).contains(original))
    }

    @Test func partialOriginalDeletionKeepsReplacementForRecovery() async throws {
        let store = TestHealthKitStore()
        let service = HealthKitService(store: store)
        try await save(service)
        let original = try #require(try await fetch(service).first)
        await store.failAfterDeleting(original.id)
        do {
            try await service.updateReading(original, systolic: 130, diastolic: 85, pulse: 75, at: timestamp)
            Issue.record("Expected recovery failure")
        } catch HealthKitError.updateRecoveryFailed {} catch { Issue.record("Unexpected error: \(error)") }
        let remaining = try await fetch(service)
        #expect(remaining.count == 1)
        #expect(remaining.first?.systolic == 130)
        #expect(remaining.first?.pulse == 75)
        #expect(await store.deleteCalls == 1)
    }

    @Test func missingUUIDNeverFallsBackToMatchingValues() async throws {
        let store = TestHealthKitStore()
        let service = HealthKitService(store: store)
        try await save(service)
        let missing = StoredBloodPressureReading(systolic: 120, diastolic: 80, pulse: 70, timestamp: timestamp)
        await #expect(throws: HealthKitError.self) { try await service.deleteReading(missing) }
        await #expect(throws: HealthKitError.self) {
            try await service.updateReading(missing, systolic: 130, diastolic: 85, pulse: 75, at: timestamp)
        }
        #expect(await store.saveCalls == 1)
        #expect(await store.deleteCalls == 0)
    }

    @Test func foreignReadingCannotBeEditedOrDeleted() async throws {
        let store = TestHealthKitStore()
        let service = HealthKitService(store: store)
        try await save(service)
        let original = try #require(try await fetch(service).first)
        await store.markForeign(original.id)
        await #expect(throws: HealthKitError.self) { try await service.deleteReading(original) }
        await #expect(throws: HealthKitError.self) {
            try await service.updateReading(original, systolic: 130, diastolic: 85, pulse: 75, at: timestamp)
        }
        #expect(await store.saveCalls == 1)
        #expect(await store.deleteCalls == 0)
    }

    @Test func legacyNearbyPulseIsDisplayedButNeverDeleted() async throws {
        let store = TestHealthKitStore()
        let sys = quantity(.bloodPressureSystolic, value: 120)
        let dia = quantity(.bloodPressureDiastolic, value: 80)
        let correlation = HKCorrelation(type: HKCorrelationType(.bloodPressure), start: timestamp, end: timestamp, objects: [sys, dia])
        let pulse = quantity(.heartRate, value: 70)
        try await store.save([correlation, pulse])
        let service = HealthKitService(store: store)
        let original = try #require(try await fetch(service).first)
        #expect(original.id == correlation.uuid)
        #expect(original.pulse == 70)
        try await service.deleteReading(original)
        #expect(await store.contains(pulse.uuid))
        #expect(await store.count(of: .bloodPressureSystolic) == 0)
    }

    @Test func explicitPulseUUIDWinsOverNearbyUnrelatedPulse() async throws {
        let store = TestHealthKitStore()
        let unrelated = quantity(.heartRate, value: 95)
        try await store.save([unrelated])
        let service = HealthKitService(store: store)
        try await save(service)
        let original = try #require(try await fetch(service).first)
        #expect(original.pulse == 70)
        try await service.deleteReading(original)
        #expect(await store.contains(unrelated.uuid))
        #expect(await store.count(of: .heartRate) == 1)
    }

    @Test func deletingReadingWithoutPulseDoesNotTouchNearbyHeartRate() async throws {
        let store = TestHealthKitStore()
        let unrelated = quantity(.heartRate, value: 95)
        try await store.save([unrelated])
        let service = HealthKitService(store: store)
        try await service.saveReading(systolic: 120, diastolic: 80, pulse: nil, at: timestamp)
        let original = try #require(try await fetch(service).first)
        #expect(original.pulse == nil)
        try await service.deleteReading(original)
        #expect(await store.contains(unrelated.uuid))
    }

    @Test func reviewDisplaysUpdateRecoveryError() async {
        let viewModel = ReviewViewModel(systolic: 120, diastolic: 80, pulse: 70, timestamp: timestamp)
        let dismiss = await viewModel.save(shareAfterSavingReading: false) { _, _, _, _ in
            throw HealthKitError.updateRecoveryFailed
        }
        #expect(!dismiss)
        #expect(!viewModel.isSaving)
        #expect(viewModel.errorMessage == HealthKitError.updateRecoveryFailed.localizedDescription)
    }

    private var timestamp: Date { Date(timeIntervalSince1970: 1_700_000_000) }
    private func save(_ service: HealthKitService) async throws {
        try await service.saveReading(systolic: 120, diastolic: 80, pulse: 70, at: timestamp)
    }
    private func fetch(_ service: HealthKitService) async throws -> [StoredBloodPressureReading] {
        try await service.fetchReadings(startDate: timestamp.addingTimeInterval(-10), endDate: timestamp.addingTimeInterval(10))
    }
    private func quantity(_ identifier: HKQuantityTypeIdentifier, value: Double) -> HKQuantitySample {
        let unit = identifier == .heartRate ? HKUnit.count().unitDivided(by: .minute()) : .millimeterOfMercury()
        return HKQuantitySample(type: HKQuantityType(identifier), quantity: HKQuantity(unit: unit, doubleValue: value), start: timestamp, end: timestamp)
    }
}

private enum TestStoreError: Error { case injected }

private actor TestHealthKitStore: HealthKitStoring {
    private var objects: [HKSample] = []
    private var foreignIDs: Set<UUID> = []
    private var saveShouldFail = false
    private var deleteFailures = 0
    private var partialDeletionID: UUID?
    private(set) var saveCalls = 0
    private(set) var deleteCalls = 0

    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws {}
    func owns(_ sample: HKSample) async -> Bool { !foreignIDs.contains(sample.uuid) }
    // Deliberately return all objects of the type: the service must still enforce identity.
    func samples(of type: HKSampleType, matching filter: HealthKitSampleFilter) async throws -> [HKSample] {
        objects.filter { $0.sampleType == type }
    }
    func save(_ samples: [HKSample]) async throws {
        saveCalls += 1
        if saveShouldFail { saveShouldFail = false; throw TestStoreError.injected }
        objects.append(contentsOf: samples)
        objects.append(contentsOf: samples.compactMap { $0 as? HKCorrelation }.flatMap { Array($0.objects) })
    }
    func delete(_ samples: [HKSample]) async throws {
        deleteCalls += 1
        if let id = partialDeletionID {
            partialDeletionID = nil
            objects.removeAll { $0.uuid == id }
            throw TestStoreError.injected
        }
        if deleteFailures > 0 { deleteFailures -= 1; throw TestStoreError.injected }
        let ids = Set(samples.map(\.uuid))
        objects.removeAll { ids.contains($0.uuid) }
    }
    func failAfterDeleting(_ id: UUID) { partialDeletionID = id }
    func failNextSave() { saveShouldFail = true }
    func failDeletes(_ count: Int) { deleteFailures = count }
    func markForeign(_ id: UUID) { foreignIDs.insert(id) }
    func contains(_ id: UUID) -> Bool { objects.contains { $0.uuid == id } }
    func count(of identifier: HKQuantityTypeIdentifier) -> Int {
        objects.filter { $0.sampleType == HKQuantityType(identifier) }.count
    }
}
