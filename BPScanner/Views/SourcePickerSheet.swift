// MARK: Views/SourcePickerSheet.swift

import ImageIO
import PhotosUI
import Photos
import SwiftUI

/// Sheet view for selecting image source: camera or photo library.
struct SourcePickerSheet: View {
    @State private var selectedPhotoItem: PhotosPickerItem?
    @Environment(\.dismiss) var dismiss

    let onTakePhoto: () -> Void
    let onLibrarySelection: (UIImage, Date) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Camera option
                Button {
                    dismiss()
                    onTakePhoto()
                } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 40))
                        Text("Take Photo", bundle: .main)
                            .font(.headline)
                        Text("Use device camera", bundle: .main)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                .foregroundColor(.primary)

                // Photo library option
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    preferredItemEncoding: .current
                ) {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 40))
                        Text("Choose from Library", bundle: .main)
                            .font(.headline)
                        Text("Select existing photo", bundle: .main)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                .foregroundColor(.primary)

                Spacer()
            }
            .padding()
            .navigationTitle(String(localized: "Choose Source", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Cancel", bundle: .main)) {
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: selectedPhotoItem) {
            guard let selectedPhotoItem else { return }

            Task {
                await handlePhotoSelection(selectedPhotoItem)
            }
        }
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = downsampleImage(from: data) {
                let timestamp = (try await extractTimestamp(from: item)) ?? Date()
                dismiss()
                onLibrarySelection(image, timestamp)
            }
        } catch {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = downsampleImage(from: data) {
                dismiss()
                onLibrarySelection(image, Date())
            }
        }

        selectedPhotoItem = nil
    }

    private func extractTimestamp(from item: PhotosPickerItem) async throws -> Date? {
        let itemIdentifier = item.itemIdentifier
        guard let itemIdentifier = itemIdentifier else { return nil }

        // Access PHAsset to get creation date
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [itemIdentifier], options: nil)
        guard let asset = result.firstObject else { return nil }

        return asset.creationDate
    }

    private func downsampleImage(from data: Data, maxPixelSize: CGFloat = 1800) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return UIImage(data: data)
        }

        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return UIImage(data: data)
        }

        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    SourcePickerSheet(
        onTakePhoto: {},
        onLibrarySelection: { _, _ in }
    )
}
