//
//  SettingsView.swift
//  Nextcloud Gallery
//
//  Account + on-device storage settings, presented as a sheet.
//

import SwiftUI

/// Lets the user sign out or wipe the on-device cache (without signing out).
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirmation = false
    @State private var isClearing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        HStack {
                            Label("Clear Local Cache", systemImage: "trash")
                            if isClearing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isClearing)
                } footer: {
                    Text("Deletes the cached folder structure, thumbnails, and downloaded photos from this device. You'll stay signed in, and your library re-downloads as you browse.")
                }

                Section {
                    Button(role: .destructive) {
                        environment.signOut()
                        dismiss()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(isClearing)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isClearing)
                }
            }
            .confirmationDialog(
                "Clear Local Cache?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Cache", role: .destructive) {
                    Task {
                        isClearing = true
                        await environment.clearLocalCache()
                        isClearing = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes all cached folders, thumbnails, and downloaded photos from this device. You'll stay signed in.")
            }
            .interactiveDismissDisabled(isClearing)
        }
    }
}
