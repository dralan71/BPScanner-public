import Combine
import Foundation
import Photos
import SwiftUI

@MainActor
final class MainViewModel: ObservableObject {
    private enum UserDefaultsKeys {
        static let autoSaveCapturedPhotos = "autoSaveCapturedPhotos"
        static let shareAfterSavingReading = "shareAfterSavingReading"
    }

    enum TimeRange: String, CaseIterable {
        case day = "Day"
        case week = "Week"
        case month = "Month"

        var localizedKey: String {
            rawValue
        }

        func dateRange(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
            let end = calendar.startOfDay(for: now).addingTimeInterval(86400 - 1)
            let start: Date

            switch self {
            case .day:
                start = calendar.startOfDay(for: now)
            case .week:
                let days = calendar.dateComponents([.weekday], from: now).weekday ?? 1
                let daysToSubtract = max(0, days - 1)
                start = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(-daysToSubtract * 86400))
            case .month:
                let numberOfDays = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
                start = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(-numberOfDays * 86400))
            }

            return (start, end)
        }
    }

    enum ScanState {
        case idle
        case sourcePickerSheet
        case camera
        case processing(UIImage, Date)
        case review(Int, Int, Int?, Date, UIImage)
        case manualEntry(Date, UIImage)
    }

    struct PendingScan {
        let image: UIImage
        let timestamp: Date
    }

    @Published var scanState: ScanState = .idle
    @Published var timeRange: TimeRange = .week
    @Published private(set) var readings: [StoredBloodPressureReading] = []
    @Published var isShowingSettings = false
    @Published var isShowingPhotoLibraryAccessAlert = false
    @Published var autoSaveCapturedPhotos: Bool {
        didSet {
            UserDefaults.standard.set(autoSaveCapturedPhotos, forKey: UserDefaultsKeys.autoSaveCapturedPhotos)
        }
    }
    @Published var shareAfterSavingReading: Bool {
        didSet {
            UserDefaults.standard.set(shareAfterSavingReading, forKey: UserDefaultsKeys.shareAfterSavingReading)
        }
    }

    private var pendingScan: PendingScan?
    private var shouldOpenCameraAfterSourcePicker = false
    private var shouldOpenCameraAfterProcessingFailure = false
    private let healthKitService: any HealthKitServicing

    init(healthKitService: any HealthKitServicing = HealthKitService.shared) {
        self.autoSaveCapturedPhotos = UserDefaults.standard.object(forKey: UserDefaultsKeys.autoSaveCapturedPhotos) as? Bool ?? false
        self.shareAfterSavingReading = UserDefaults.standard.object(forKey: UserDefaultsKeys.shareAfterSavingReading) as? Bool ?? true
        self.healthKitService = healthKitService
    }

    var isSourcePickerVisible: Bool {
        if case .sourcePickerSheet = scanState { return true }
        return false
    }

    var isProcessingVisible: Bool {
        if case .processing = scanState { return true }
        return false
    }

    var isCameraVisible: Bool {
        if case .camera = scanState { return true }
        return false
    }

    var isReviewVisible: Bool {
        if case .review = scanState { return true }
        return false
    }

    var isManualEntryVisible: Bool {
        if case .manualEntry = scanState { return true }
        return false
    }

    func sourcePickerBinding() -> Binding<Bool> {
        Binding(
            get: { self.isSourcePickerVisible },
            set: { isPresented in
                if !isPresented, case .sourcePickerSheet = self.scanState {
                    self.scanState = .idle
                }
            }
        )
    }

    func processingBinding() -> Binding<Bool> {
        Binding(
            get: { self.isProcessingVisible },
            set: { isPresented in
                if !isPresented, case .processing = self.scanState {
                    self.scanState = .idle
                }
            }
        )
    }

    func cameraBinding() -> Binding<Bool> {
        Binding(
            get: { self.isCameraVisible },
            set: { isPresented in
                if !isPresented, case .camera = self.scanState {
                    self.scanState = .idle
                }
            }
        )
    }

    func reviewBinding() -> Binding<Bool> {
        Binding(
            get: { self.isReviewVisible },
            set: { isPresented in
                if !isPresented, case .review = self.scanState {
                    self.scanState = .idle
                }
            }
        )
    }

    func manualEntryBinding() -> Binding<Bool> {
        Binding(
            get: { self.isManualEntryVisible },
            set: { isPresented in
                if !isPresented, case .manualEntry = self.scanState {
                    self.scanState = .idle
                }
            }
        )
    }

    func beginScan() {
        scanState = .sourcePickerSheet
    }

    func queuePendingScan(image: UIImage, timestamp: Date) {
        pendingScan = PendingScan(image: image, timestamp: timestamp)
        scanState = .idle
    }

    func retryCaptureAfterSourceSelection() {
        shouldOpenCameraAfterSourcePicker = true
        scanState = .idle
    }

    func retryCaptureAfterProcessingFailure() {
        shouldOpenCameraAfterProcessingFailure = true
        scanState = .idle
    }

    func cancelCamera() {
        scanState = .idle
    }

    func showReview(systolic: Int, diastolic: Int, pulse: Int?, timestamp: Date, image: UIImage) {
        scanState = .review(systolic, diastolic, pulse, timestamp, image)
    }

    func showManualEntry(timestamp: Date, image: UIImage) {
        scanState = .manualEntry(timestamp, image)
    }

    func presentPendingScanIfNeeded() {
        if shouldOpenCameraAfterSourcePicker || shouldOpenCameraAfterProcessingFailure {
            shouldOpenCameraAfterSourcePicker = false
            shouldOpenCameraAfterProcessingFailure = false
            DispatchQueue.main.async {
                self.scanState = .camera
            }
            return
        }

        guard let pendingScan else { return }

        self.pendingScan = nil
        DispatchQueue.main.async {
            self.scanState = .processing(pendingScan.image, pendingScan.timestamp)
        }
    }

    func loadReadings() async {
        let range = timeRange.dateRange()

        do {
            try await healthKitService.requestAuthorization()
            readings = try await healthKitService.fetchReadings(startDate: range.start, endDate: range.end)
        } catch {
            readings = []
        }
    }

    func saveReading(systolic: Int, diastolic: Int, pulse: Int?, timestamp: Date) async throws {
        try await healthKitService.requestAuthorization()
        try await healthKitService.saveReading(systolic: systolic, diastolic: diastolic, pulse: pulse, at: timestamp)
        await loadReadings()
    }

    func updateReading(
        _ originalReading: StoredBloodPressureReading,
        systolic: Int,
        diastolic: Int,
        pulse: Int?,
        timestamp: Date
    ) async throws {
        try await healthKitService.requestAuthorization()
        try await healthKitService.updateReading(
            originalReading,
            systolic: systolic,
            diastolic: diastolic,
            pulse: pulse,
            at: timestamp
        )
        await loadReadings()
    }

    func enableAutoSaveCapturedPhotos() async -> Bool {
        let status = await requestPhotoLibraryAddAuthorizationIfNeeded()
        let isAuthorized = status == .authorized || status == .limited
        isShowingPhotoLibraryAccessAlert = !isAuthorized
        return isAuthorized
    }

    private func requestPhotoLibraryAddAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
