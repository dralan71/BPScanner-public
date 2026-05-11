// MARK: Views/MainView.swift

import Foundation
import Photos
import SwiftUI

/// Main app screen showing recent BP data and scan button.
struct MainView: View {
    @StateObject private var viewModel: MainViewModel
    @State private var visibleReadingCount = 5
    @State private var selectedReading: StoredBloodPressureReading?
    @State private var pendingDeleteReading: StoredBloodPressureReading?
    
    @MainActor
    init(viewModel: MainViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? MainViewModel())
    }

    var body: some View {
        NavigationStack {
            readingsContent
            .safeAreaInset(edge: .bottom) {
                scanButton
                    .padding()
                    .background(.background)
            }
            .navigationTitle(String(localized: "BP Scanner", bundle: .main))
            .navigationDestination(isPresented: viewModel.reviewBinding()) {
                reviewView
            }
            .navigationDestination(isPresented: viewModel.manualEntryBinding()) {
                manualEntryView
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        viewModel.isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(String(localized: "Settings", bundle: .main))
                }
            }
            .sheet(isPresented: viewModel.sourcePickerBinding(), onDismiss: viewModel.presentPendingScanIfNeeded) {
                SourcePickerSheet(
                    onTakePhoto: {
                        viewModel.retryCaptureAfterSourceSelection()
                    },
                    onLibrarySelection: { image, timestamp in
                        viewModel.queuePendingScan(image: image, timestamp: timestamp)
                    }
                )
            }
            .fullScreenCover(isPresented: viewModel.cameraBinding(), onDismiss: viewModel.presentPendingScanIfNeeded) {
                CameraView(
                    shouldAutoSaveToPhotoLibrary: viewModel.autoSaveCapturedPhotos,
                    onCapture: { image, timestamp in
                        viewModel.queuePendingScan(image: image, timestamp: timestamp)
                    },
                    onCancel: {
                        viewModel.cancelCamera()
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $viewModel.isShowingSettings) {
                NavigationStack {
                    Form {
                        Toggle(
                            String(localized: "Auto-save captured photos", bundle: .main),
                            isOn: Binding(
                                get: { viewModel.autoSaveCapturedPhotos },
                                set: { isEnabled in
                                    if isEnabled {
                                        Task {
                                            viewModel.autoSaveCapturedPhotos = await viewModel.enableAutoSaveCapturedPhotos()
                                        }
                                    } else {
                                        viewModel.autoSaveCapturedPhotos = false
                                    }
                                }
                            )
                        )

                        Text("When enabled, photos taken with the in-app camera are also saved to your photo library.", bundle: .main)
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Toggle(
                            String(localized: "Share after saving from review", bundle: .main),
                            isOn: $viewModel.shareAfterSavingReading
                        )

                        Text("When enabled, the review screen uses Save and Share and presents the iOS share sheet after a successful save.", bundle: .main)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .navigationTitle(String(localized: "Settings", bundle: .main))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button(String(localized: "Done", bundle: .main)) {
                                viewModel.isShowingSettings = false
                            }
                        }
                    }
                }
            }
            .sheet(item: $selectedReading) { reading in
                ReadingDetailView(
                    reading: reading,
                    onSave: { sys, dia, pulse, ts in
                        try await viewModel.updateReading(
                            reading,
                            systolic: sys,
                            diastolic: dia,
                            pulse: pulse,
                            timestamp: ts
                        )
                    },
                    onDelete: {
                        try await viewModel.deleteReading(reading)
                    }
                )
            }
            .alert(String(localized: "Photo Access Needed", bundle: .main), isPresented: $viewModel.isShowingPhotoLibraryAccessAlert) {
                Button(String(localized: "OK", bundle: .main), role: .cancel) {}
            } message: {
                Text("Allow photo library access to auto-save captured photos.", bundle: .main)
            }
            .alert(
                String(localized: "Delete Reading?", bundle: .main),
                isPresented: deleteConfirmationBinding
            ) {
                Button(String(localized: "Delete", bundle: .main), role: .destructive) {
                    confirmDeleteReading()
                }
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) {
                    pendingDeleteReading = nil
                }
            } message: {
                Text("This removes the reading from HealthKit.", bundle: .main)
            }
            .fullScreenCover(isPresented: viewModel.processingBinding(), onDismiss: viewModel.presentPendingScanIfNeeded) {
                Group {
                    if case let .processing(image, timestamp) = viewModel.scanState {
                        ScanProcessingView(
                            image: image,
                            timestamp: timestamp,
                            onSuccess: { sys, dia, pulse, ts, img in
                                viewModel.showReview(systolic: sys, diastolic: dia, pulse: pulse, timestamp: ts, image: img)
                            },
                            onFailure: { ts, img in
                                viewModel.showManualEntry(timestamp: ts, image: img)
                            },
                            onRetryCapture: {
                                viewModel.retryCaptureAfterProcessingFailure()
                            }
                        )
                    } else {
                        EmptyView()
                    }
                }
            }
            .onAppear {
                Task {
                    await viewModel.loadReadings()
                }
            }
            .onChange(of: viewModel.readings.count) {
                visibleReadingCount = 5
            }
        }
    }

    @ViewBuilder
    private var readingsContent: some View {
        if viewModel.readings.isEmpty {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("No readings yet", bundle: .main)
                        .font(.headline)
                    Text("Tap the button below to add your first one.", bundle: .main)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: 360)
            }
            .padding(.vertical)
        } else {
            List {
                Section {
                    ForEach(displayedReadings) { reading in
                        readingRow(for: reading)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }

                    if canShowMoreReadings {
                        Button {
                            visibleReadingCount = min(visibleReadingCount + 5, maximumVisibleReadings)
                        } label: {
                            Text("Show more", bundle: .main)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Recent readings", bundle: .main)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
        }
    }

    private var scanButton: some View {
        Button(action: viewModel.beginScan) {
            HStack {
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                Text("Scan Reading", bundle: .main)
                    .fontWeight(.semibold)
                Spacer()
            }
            .foregroundColor(.white)
            .padding(16)
            .background(Color.blue)
            .cornerRadius(12)
        }
    }

    var reviewView: ReviewView {
        if case let .review(sys, dia, pulse, ts, image) = viewModel.scanState {
            return ReviewView(
                image: image,
                systolic: sys,
                diastolic: dia,
                pulse: pulse,
                timestamp: ts,
                onSave: { sys, dia, pulse, ts in
                    try await viewModel.saveReading(systolic: sys, diastolic: dia, pulse: pulse, timestamp: ts)
                }
            )
        }
        return ReviewView(
            image: UIImage(),
            systolic: 0,
            diastolic: 0,
            pulse: nil,
            timestamp: Date(),
            onSave: { _, _, _, _ in }
        )
    }

    var manualEntryView: ManualEntryView {
        if case let .manualEntry(ts, _) = viewModel.scanState {
            return ManualEntryView(
                defaultDate: ts,
                onSave: { sys, dia, pulse, ts in
                    try await viewModel.saveReading(systolic: sys, diastolic: dia, pulse: pulse, timestamp: ts)
                }
            )
        }
        return ManualEntryView(onSave: { _, _, _, _ in })
    }

    private var sortedReadings: [StoredBloodPressureReading] {
        viewModel.readings.sorted { $0.timestamp > $1.timestamp }
    }

    private var displayedReadings: ArraySlice<StoredBloodPressureReading> {
        sortedReadings.prefix(visibleReadingCount)
    }

    private var maximumVisibleReadings: Int {
        min(20, sortedReadings.count)
    }

    private var canShowMoreReadings: Bool {
        visibleReadingCount < maximumVisibleReadings
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteReading != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteReading = nil
                }
            }
        )
    }

    @ViewBuilder
    private func readingRow(for reading: StoredBloodPressureReading) -> some View {
        Button {
            selectedReading = reading
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(reading.systolic)/\(reading.diastolic)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("mmHg", bundle: .main)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let pulse = reading.pulse {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                            Text("\(pulse) bpm")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    }
                }

                Text(reading.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                pendingDeleteReading = reading
            } label: {
                Label(String(localized: "Delete", bundle: .main), systemImage: "trash")
            }
        }
    }

    private func confirmDeleteReading() {
        guard let reading = pendingDeleteReading else { return }

        pendingDeleteReading = nil
        Task {
            try? await viewModel.deleteReading(reading)
        }
    }
}

#Preview {
    MainView(viewModel: MainViewModel(healthKitService: PreviewHealthKitService()))
}

private struct PreviewHealthKitService: HealthKitServicing {
    func requestAuthorization() async throws {}

    func saveReading(systolic: Int, diastolic: Int, pulse: Int?, at timestamp: Date) async throws {}

    func updateReading(
        _ originalReading: StoredBloodPressureReading,
        systolic: Int,
        diastolic: Int,
        pulse: Int?,
        at timestamp: Date
    ) async throws {}

    func deleteReading(_ reading: StoredBloodPressureReading) async throws {}

    func fetchReadings(startDate: Date, endDate: Date) async throws -> [StoredBloodPressureReading] {
        let calendar = Calendar.current
        let now = Date()

        return [
            StoredBloodPressureReading(systolic: 118, diastolic: 76, pulse: 64, timestamp: now),
            StoredBloodPressureReading(systolic: 121, diastolic: 79, pulse: 68, timestamp: calendar.date(byAdding: .day, value: -1, to: now) ?? now),
            StoredBloodPressureReading(systolic: 125, diastolic: 81, pulse: 70, timestamp: calendar.date(byAdding: .day, value: -2, to: now) ?? now),
            StoredBloodPressureReading(systolic: 116, diastolic: 74, pulse: 63, timestamp: calendar.date(byAdding: .day, value: -3, to: now) ?? now),
            StoredBloodPressureReading(systolic: 129, diastolic: 83, pulse: 72, timestamp: calendar.date(byAdding: .day, value: -4, to: now) ?? now),
            StoredBloodPressureReading(systolic: 122, diastolic: 78, pulse: 66, timestamp: calendar.date(byAdding: .day, value: -5, to: now) ?? now),
            StoredBloodPressureReading(systolic: 116, diastolic: 74, pulse: 63, timestamp: calendar.date(byAdding: .day, value: -6, to: now) ?? now),
            StoredBloodPressureReading(systolic: 129, diastolic: 83, pulse: 72, timestamp: calendar.date(byAdding: .day, value: -7, to: now) ?? now),
            StoredBloodPressureReading(systolic: 122, diastolic: 78, pulse: 66, timestamp: calendar.date(byAdding: .day, value: -8, to: now) ?? now),
        ]
    }
}
