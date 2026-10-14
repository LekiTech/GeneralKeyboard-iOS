//
//  ReferenceApp.swift
//  ReferenceApp
//
//  The reference containing app: the shared onboarding screen and the
//  contribution inbox pickup, exactly as a product wires them. Dev-only;
//  never submitted.
//

import SwiftUI
import GeneralKeyboardApp
import GeneralKeyboardBridge

@main
struct ReferenceApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var sample = ""

    var body: some Scene {
        WindowGroup {
            KeyboardOnboardingView(
                title: "General Keyboard",
                tagline: "Reference keyboard",
                keyboardName: "GK Reference",
                features: [
                    .init(0, icon: "textformat.abc", tint: .blue,
                          title: "Reference definition",
                          subtitle: "Every engine capability on, Avar fixture data"),
                    .init(1, icon: "lock.shield.fill", tint: .purple,
                          title: "Private by design",
                          subtitle: "No Full Access, nothing leaves the device"),
                ]) {
                    // Product slot: a field to try the keyboard without
                    // leaving the app.
                    OnboardingCard {
                        Text(verbatim: "Try it")
                            .font(.title3.weight(.semibold))
                        TextField(text: $sample, prompt: Text(verbatim: "Type here"), axis: .vertical) {
                            Text(verbatim: "Sample")
                        }
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active,
                  let bridge = ContributionBridge.productionDirectory(
                      appGroupID: "group.org.lekitech.generalkeyboard") else { return }
            ContributionInbox.pickUp(from: bridge)
        }
    }
}
