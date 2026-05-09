// MARK: Views/ReviewView.swift

import SwiftUI
import UIKit

/// View for reviewing and confirming scanned blood pressure readings.
struct ReviewView: View {
    @AppStorage("shareAfterSavingReading") private var shareAfterSavingReading = true
    @StateObject private var viewModel: ReviewViewModel
    @FocusState private var focusedField: ReviewViewModel.EntryField?
    @Environment(\.dismiss) var dismiss

    let image: UIImage
    let onSave: (Int, Int, Int?, Date) async throws -> Void

    init(
        image: UIImage,
        systolic: Int,
        diastolic: Int,
        pulse: Int?,
        timestamp: Date,
        onSave: @escaping (Int, Int, Int?, Date) async throws -> Void
    ) {
        self.image = image
        self.onSave = onSave
        _viewModel = StateObject(wrappedValue: ReviewViewModel(
            systolic: systolic,
            diastolic: diastolic,
            pulse: pulse,
            timestamp: timestamp
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        // Image preview
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .aspectRatio(3.0 / 4.0, contentMode: .fit)
                            .cornerRadius(8)

                        // Editable fields
                        VStack(spacing: 16) {
                            entryCard(
                                title: String(localized: "Systolic (SYS)", bundle: .main),
                                value: $viewModel.systolic,
                                unit: String(localized: "mmHg", bundle: .main),
                                field: .systolic,
                                helperText: viewModel.showSystolicWarning
                                    ? String(localized: "Value outside normal range (90–180)", bundle: .main)
                                    : nil
                            )
                            .id(ReviewViewModel.EntryField.systolic)

                            entryCard(
                                title: String(localized: "Diastolic (DIA)", bundle: .main),
                                value: $viewModel.diastolic,
                                unit: String(localized: "mmHg", bundle: .main),
                                field: .diastolic,
                                helperText: viewModel.showDiastolicWarning
                                    ? String(localized: "Value outside normal range (50–120)", bundle: .main)
                                    : nil
                            )
                            .id(ReviewViewModel.EntryField.diastolic)

                            entryCard(
                                title: String(localized: "Pulse (PUL)", bundle: .main),
                                value: $viewModel.pulse,
                                unit: String(localized: "bpm", bundle: .main),
                                field: .pulse,
                                accessoryText: String(localized: "Optional", bundle: .main)
                            )
                            .id(ReviewViewModel.EntryField.pulse)
                        }
                        .padding(.horizontal)

                        // Date/time display
                        HStack {
                            Image(systemName: "calendar")
                                .foregroundColor(.gray)
                            Text(viewModel.formattedDate)
                                .foregroundColor(.gray)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .font(.callout)

                        Spacer()

                        // Save button
                        VStack(spacing: 12) {
                            Button(action: save) {
                                HStack {
                                    Spacer()
                                    Text(shareAfterSavingReading ? "Save and Share" : "Save to Health", bundle: .main)
                                        .fontWeight(.semibold)
                                    Spacer()
                                }
                                .foregroundColor(.white)
                                .padding(16)
                                .background(viewModel.isValid && !viewModel.isSaving ? Color.blue : Color.gray)
                                .cornerRadius(8)
                            }
                            .disabled(!viewModel.isValid || viewModel.isSaving)
                        }
                        .padding(.horizontal)
                    }
                    .padding()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedField = nil
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: focusedField) { _, newField in
                    guard let newField else { return }
                    scrollToFocusedField(newField, with: proxy)
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear
                        .frame(height: focusedField == nil ? 0 : 12)
                }
            }
            .navigationTitle(String(localized: "Confirm Reading", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.isShowingDismissAlert = true
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .disabled(viewModel.isSaving)
                    .accessibilityLabel(String(localized: "Close", bundle: .main))
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "Done", bundle: .main)) {
                        focusedField = nil
                    }
                }
            }
            .sheet(isPresented: $viewModel.isShowingShareSheet, onDismiss: {
                dismiss()
            }) {
                ActivityViewController(activityItems: viewModel.shareItems)
            }
            .alert(String(localized: "Leave Review?", bundle: .main), isPresented: $viewModel.isShowingDismissAlert) {
                Button(shareAfterSavingReading ? String(localized: "Save and Share", bundle: .main) : String(localized: "Save", bundle: .main)) {
                    save()
                }
                Button(String(localized: "Discard", bundle: .main), role: .destructive) {
                    dismiss()
                }
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
            } message: {
                Text("Choose whether to save this reading before leaving.", bundle: .main)
            }
        }
    }

    @ViewBuilder
    private func entryCard(
        title: String,
        value: Binding<String>,
        unit: String,
        field: ReviewViewModel.EntryField,
        accessoryText: String? = nil,
        helperText: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                if let accessoryText {
                    Text(accessoryText)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            HStack {
                TextField("", text: value)
                    .keyboardType(.numberPad)
                    .font(.system(size: 28, weight: .semibold))
                    .focused($focusedField, equals: field)
                Text(unit)
                    .foregroundColor(.gray)
            }

            if let helperText {
                Text(helperText)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    private func scrollToFocusedField(_ field: ReviewViewModel.EntryField, with proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(field, anchor: .center)
        }
    }

    private func save() {
        Task {
            let shouldDismiss = await viewModel.save(
                shareAfterSavingReading: shareAfterSavingReading,
                onSave: onSave
            )

            if shouldDismiss {
                dismiss()
            }
        }
    }
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    let testImage = UIImage(systemName: "square.fill") ?? UIImage()
    ReviewView(
        image: testImage,
        systolic: 121,
        diastolic: 79,
        pulse: 72,
        timestamp: Date()
    ) { _, _, _, _ in }
}
