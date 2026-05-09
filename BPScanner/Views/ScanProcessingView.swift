// MARK: Views/ScanProcessingView.swift

import Foundation
import SwiftUI

/// View displayed while scanning and processing an image.
struct ScanProcessingView: View {
    @StateObject private var viewModel = ScanProcessingViewModel()
    @Environment(\.dismiss) var dismiss

    let image: UIImage
    let timestamp: Date
    let onSuccess: (Int, Int, Int?, Date, UIImage) -> Void
    let onFailure: (Date, UIImage) -> Void
    let onRetryCapture: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                if let errorMessage = viewModel.errorMessage {
                    // Error state
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)

                        Text("Unable to scan", bundle: .main)
                            .font(.system(size: 18, weight: .semibold))

                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)

                        Button(String(localized: "Enter Manually", bundle: .main)) {
                            onFailure(timestamp, image)
                        }
                        .foregroundColor(.blue)

                        Button(String(localized: "Try Again", bundle: .main)) {
                            onRetryCapture()
                        }
                        .foregroundColor(.blue)
                    }
                    .padding()
                } else if viewModel.isProcessing {
                    // Processing state
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)

                        Text("Reading your monitor...", bundle: .main)
                            .font(.system(size: 18, weight: .semibold))
                        
                        Text("Processing image...", bundle: .main)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                } else {
                    // Shouldn't reach here - auto-navigate instead
                    VStack {
                        Text("Processing complete", bundle: .main)
                        Button(String(localized: "Cancel", bundle: .main)) {
                            dismiss()
                        }
                        .foregroundColor(.red)
                    }
                }

                Spacer()
            }
            .padding()
        }
        .onAppear {
            Task {
                if let reading = await viewModel.processIfNeeded(image: image) {
                    onSuccess(reading.systolic, reading.diastolic, reading.pulse, timestamp, image)
                }
            }
        }
    }
}

#Preview {
    let testImage = UIImage(systemName: "square.fill") ?? UIImage()
    ScanProcessingView(
        image: testImage,
        timestamp: Date(),
        onSuccess: { _, _, _, _, _ in },
        onFailure: { _, _ in },
        onRetryCapture: {}
    )
}
