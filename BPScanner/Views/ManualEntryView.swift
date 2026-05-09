// MARK: Views/ManualEntryView.swift

import SwiftUI

/// View for manual blood pressure entry when automatic scanning fails.
struct ManualEntryView: View {
    @StateObject private var viewModel: ManualEntryViewModel
    @FocusState private var focusedField: ManualEntryViewModel.EntryField?
    @Environment(\.dismiss) var dismiss
    let onSave: (Int, Int, Int?, Date) async throws -> Void

    init(defaultDate: Date = Date(), onSave: @escaping (Int, Int, Int?, Date) async throws -> Void) {
        _viewModel = StateObject(wrappedValue: ManualEntryViewModel(defaultDate: defaultDate))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Reading Details", bundle: .main)) {
                    HStack {
                        Text("Systolic (SYS)", bundle: .main)
                        Spacer()
                        TextField("", text: $viewModel.systolic)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .focused($focusedField, equals: .systolic)
                        Text("mmHg", bundle: .main)
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Diastolic (DIA)", bundle: .main)
                        Spacer()
                        TextField("", text: $viewModel.diastolic)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .focused($focusedField, equals: .diastolic)
                        Text("mmHg", bundle: .main)
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Pulse (PUL)", bundle: .main)
                        Spacer()
                        TextField("", text: $viewModel.pulse)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .focused($focusedField, equals: .pulse)
                        Text("bpm", bundle: .main)
                            .foregroundColor(.gray)
                    }
                }

                Section(header: Text("Date & Time", bundle: .main)) {
                    DatePicker(
                        String(localized: "Recorded at", bundle: .main),
                        selection: $viewModel.selectedDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                Section {
                    Button(action: save) {
                        HStack {
                            Spacer()
                            Text("Save to Health", bundle: .main)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!viewModel.isValid || viewModel.isSaving)
                    .foregroundColor(viewModel.isValid && !viewModel.isSaving ? .blue : .gray)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedField = nil
                    }
            }
            .navigationTitle(String(localized: "Enter Reading Manually", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "Done", bundle: .main)) {
                        focusedField = nil
                    }
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Discard", bundle: .main)) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func save() {
        Task {
            let didSave = await viewModel.save(onSave: onSave)
            if didSave {
                dismiss()
            }
        }
    }
}

#Preview {
    ManualEntryView { _, _, _, _ in }
}
