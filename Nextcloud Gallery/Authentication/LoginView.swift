//
//  LoginView.swift
//  Nextcloud Gallery
//
//  Sign-in screen: enter a server address and authenticate via the web flow.
//

import SwiftUI

struct LoginView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.layoutMetrics) private var metrics
    @State private var controller = LoginFlowController()

    var body: some View {
        @Bindable var controller = controller

        NavigationStack {
            VStack(spacing: metrics.majorSpacing) {
                Spacer()

                Image(systemName: "photo.stack")
                    .font(.system(size: metrics.largeIconSize))
                    .foregroundStyle(.tint)

                VStack(spacing: metrics.controlSpacing / 2) {
                    Text("Nextcloud Gallery")
                        .font(.largeTitle.bold())
                    Text("Sign in to browse your photos.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if controller.isAwaitingInBackground {
                    // The in-app browser closed but we're still polling — the user
                    // may be finishing in external Safari (e.g. on visionOS).
                    VStack(spacing: metrics.controlSpacing) {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Waiting for you to finish signing in…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Button("Reopen Sign-In Page") { controller.reopenBrowser() }
                            .buttonStyle(.bordered)
                        Button("Cancel", role: .cancel) { controller.cancel() }
                    }
                } else {
                    VStack(spacing: metrics.controlSpacing) {
                        TextField("cloud.example.com", text: $controller.serverURLString)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit { Task { await controller.start() } }
                            .disabled(controller.isBusy)

                        Button {
                            Task { await controller.start() }
                        } label: {
                            if controller.isBusy {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Sign In")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(controller.serverURLString.isEmpty || controller.isBusy)
                    }
                }

                if case let .failed(message) = controller.phase {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer()
                Spacer()
            }
            .frame(maxWidth: metrics.maxReadableWidth)
            .padding(metrics.contentPadding)
            .sheet(item: $controller.browserURL, onDismiss: { controller.browserDismissed() }) { item in
                // SFSafariViewController gives the best native experience on iOS,
                // but on visionOS it isn't fully supported and punts the page to
                // external Safari — so use an in-app WKWebView there instead.
                #if os(visionOS)
                WebAuthBrowserView(url: item.url)
                    .ignoresSafeArea()
                #else
                SafariView(url: item.url)
                    .ignoresSafeArea()
                #endif
            }
            .onAppear {
                controller.onComplete = { credentials in
                    environment.completeLogin(credentials)
                }
            }
        }
    }
}
