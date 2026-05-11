// MARK: Views/ReadingDetailView.swift

import SwiftUI
import UIKit

struct ReadingDetailView: View {
    @StateObject private var viewModel: ReviewViewModel
    @State private var isDeleting = false
    @State private var isShowingDeleteAlert = false
    @FocusState private var focusedField: ReviewViewModel.EntryField?
    @Environment(\.dismiss) private var dismiss

    let onSave: (Int, Int, Int?, Date) async throws -> Void
    let onDelete: () async throws -> Void

    init(
        reading: StoredBloodPressureReading,
        onSave: @escaping (Int, Int, Int?, Date) async throws -> Void,
        onDelete: @escaping () async throws -> Void
    ) {
        self.onSave = onSave
        self.onDelete = onDelete
        _viewModel = StateObject(wrappedValue: ReviewViewModel(
            systolic: reading.systolic,
            diastolic: reading.diastolic,
            pulse: reading.pulse,
            timestamp: reading.timestamp
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
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

                        HStack {
                            Image(systemName: "calendar")
                                .foregroundColor(.gray)
                            Text(viewModel.formattedDate)
                                .foregroundColor(.gray)
                            Spacer()
                        }
                        .font(.callout)

                        Button(action: save) {
                            HStack {
                                Spacer()
                                Text("Save Changes", bundle: .main)
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                            .foregroundColor(.white)
                            .padding(16)
                            .background(viewModel.isValid && !viewModel.isSaving ? Color.blue : Color.gray)
                            .cornerRadius(8)
                        }
                        .disabled(!viewModel.isValid || viewModel.isSaving)

                        Button(role: .destructive) {
                            isShowingDeleteAlert = true
                        } label: {
                            Label {
                                Text("Delete", bundle: .main)
                                    .fontWeight(.semibold)
                            } icon: {
                                Image(systemName: "trash")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.isSaving || isDeleting)
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
            }
            .navigationTitle(String(localized: "Edit Reading", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.hasChanges)
            .background(
                DismissAttemptHandler(
                    shouldDismiss: { !viewModel.hasChanges },
                    onAttempt: { viewModel.isShowingDismissAlert = true }
                )
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .disabled(viewModel.isSaving || isDeleting)
                    .accessibilityLabel(String(localized: "Close", bundle: .main))
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "Done", bundle: .main)) {
                        focusedField = nil
                    }
                }
            }
            .alert(String(localized: "Leave Review?", bundle: .main), isPresented: $viewModel.isShowingDismissAlert) {
                Button(String(localized: "Save Changes", bundle: .main)) {
                    save()
                }
                Button(String(localized: "Discard", bundle: .main), role: .destructive) {
                    dismiss()
                }
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
            } message: {
                Text("Choose whether to save this reading before leaving.", bundle: .main)
            }
            .alert(String(localized: "Delete Reading?", bundle: .main), isPresented: $isShowingDeleteAlert) {
                Button(String(localized: "Delete", bundle: .main), role: .destructive) {
                    deleteReading()
                }
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
            } message: {
                Text("This removes the reading from HealthKit.", bundle: .main)
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
                shareAfterSavingReading: false,
                onSave: onSave
            )

            if shouldDismiss {
                dismiss()
            }
        }
    }

    private func deleteReading() {
        Task {
            guard !isDeleting else { return }

            isDeleting = true
            do {
                try await onDelete()
                isDeleting = false
                dismiss()
            } catch {
                isDeleting = false
            }
        }
    }

    private func close() {
        guard viewModel.hasChanges else {
            dismiss()
            return
        }

        viewModel.isShowingDismissAlert = true
    }
}

private struct DismissAttemptHandler: UIViewControllerRepresentable {
    let shouldDismiss: () -> Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.shouldDismiss = shouldDismiss
        context.coordinator.onAttempt = onAttempt

        DispatchQueue.main.async {
            context.coordinator.attach(to: uiViewController)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldDismiss: shouldDismiss, onAttempt: onAttempt)
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var shouldDismiss: () -> Bool
        var onAttempt: () -> Void

        init(shouldDismiss: @escaping () -> Bool, onAttempt: @escaping () -> Void) {
            self.shouldDismiss = shouldDismiss
            self.onAttempt = onAttempt
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            shouldDismiss()
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            onAttempt()
        }

        func attach(to viewController: UIViewController) {
            var candidate: UIViewController? = viewController

            while let current = candidate {
                if let presentationController = current.presentationController {
                    presentationController.delegate = self
                    return
                }

                candidate = current.parent
            }

            viewController.view.window?.rootViewController?.presentedViewController?.presentationController?.delegate = self
        }
    }
}

#Preview {
    ReadingDetailView(
        reading: StoredBloodPressureReading(
            systolic: 121,
            diastolic: 79,
            pulse: 72,
            timestamp: Date()
        ),
        onSave: { _, _, _, _ in },
        onDelete: {}
    )
}
