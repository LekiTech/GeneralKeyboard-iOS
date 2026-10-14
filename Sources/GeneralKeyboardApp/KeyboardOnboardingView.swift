//
//  KeyboardOnboardingView.swift
//  GeneralKeyboardApp
//
//  The containing app's screen, shared by every keyboard: a header, the
//  "how to install" card (always visible without scrolling — the button
//  must never require a scroll), product-specific cards, feature cards and
//  the footer. Visual design carried over from the Avar app.
//
//  Product copy (title, tagline, features) is passed as LocalizedStringKey
//  and resolves in the product's own string catalog (Bundle.main). The
//  generic installation copy lives in this module's catalog (en, ru).
//

import SwiftUI

public struct KeyboardOnboardingView<Extra: View>: View {

    public struct Feature: Identifiable {
        public let id: Int
        public let icon: String
        public let tint: Color
        public let title: LocalizedStringKey
        public let subtitle: LocalizedStringKey

        public init(_ id: Int, icon: String, tint: Color,
                    title: LocalizedStringKey, subtitle: LocalizedStringKey) {
            self.id = id
            self.icon = icon
            self.tint = tint
            self.title = title
            self.subtitle = subtitle
        }
    }

    private let title: LocalizedStringKey
    private let tagline: LocalizedStringKey
    private let keyboardName: String
    private let features: [Feature]
    private let extra: Extra

    @Environment(\.openURL) private var openURL

    /// - Parameters:
    ///   - keyboardName: the keyboard's name exactly as Settings → Keyboards
    ///     lists it (the extension's display name), shown in step 3.
    ///   - extra: product cards placed between the install card and the
    ///     feature cards.
    public init(title: LocalizedStringKey,
                tagline: LocalizedStringKey,
                keyboardName: String,
                features: [Feature],
                @ViewBuilder extra: () -> Extra) {
        self.title = title
        self.tagline = tagline
        self.keyboardName = keyboardName
        self.features = features
        self.extra = extra()
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                installCard
                extra
                featureCards
                footer
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [.blue, .indigo],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                )
            Text(title)
                .font(.title.weight(.bold))
            Text(tagline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Installation

    private var installCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How to install", bundle: .module)
                .font(.title3.weight(.semibold))

            StepRow(number: "1", text: Text("Tap **Open Settings** below", bundle: .module))
            StepRow(number: "2", text: Text("Tap **Keyboards**", bundle: .module))
            StepRow(number: "3", text: Text("Turn on **\(keyboardName)**", bundle: .module))
            StepRow(number: "4", text: Text("Switch languages using the 🌐 key on the keyboard",
                                            bundle: .module))

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Text("Open Settings", bundle: .module)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)

            Text("Tip: you can also add the keyboard via **Settings → General → Keyboard → Keyboards**",
                 bundle: .module)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Features and footer

    private var featureCards: some View {
        VStack(spacing: 12) {
            ForEach(features) { feature in
                FeatureCard(icon: feature.icon, tint: feature.tint,
                            title: feature.title, subtitle: feature.subtitle)
            }
        }
    }

    private var footer: some View {
        Text("Developed by LekiTech", bundle: .module)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 8)
    }
}

extension KeyboardOnboardingView where Extra == EmptyView {
    public init(title: LocalizedStringKey, tagline: LocalizedStringKey,
                keyboardName: String, features: [Feature]) {
        self.init(title: title, tagline: tagline, keyboardName: keyboardName,
                  features: features) { EmptyView() }
    }
}

// MARK: - Building blocks

/// A card styled like the install card, for product sections.
public struct OnboardingCard<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FeatureCard: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct StepRow: View {
    let number: String
    let text: Text

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(verbatim: number)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor)
                .clipShape(Circle())
            text
                .font(.body)
        }
    }
}

/// This module's resource bundle, for products and tests that need the
/// generic onboarding strings outside a SwiftUI `Text`.
public enum GeneralKeyboardAppResources {
    public static var bundle: Bundle { .module }
}
