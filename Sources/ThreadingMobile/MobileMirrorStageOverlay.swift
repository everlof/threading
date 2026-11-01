import SwiftUI
import ThreadingRemoteKit
import UIKit

/// Everything the stage draws over the page. It is media chrome over arbitrary content, so it
/// keeps its own dark, translucent material rather than the app palette — the same reason a video
/// player's controls do — and draws nothing at all until the person calls it.
struct MobileMirrorStageOverlay: View {
    @ObservedObject var model: MobileMirrorStageModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        ZStack {
            switch model.phase {
            case .connecting:
                MobileLoadingPlaceholder(
                    MobileL10n.string("Connecting to %@", model.macName),
                    standsOnContent: true
                )
                .padding(.horizontal, 32)
            case let .failed(message):
                statusCard(message, showsEnd: true)
            case let .ended(message):
                statusCard(message, showsEnd: false)
            case .live:
                EmptyView()
            }

            if model.isStandby {
                MobileMirrorStandby(macName: model.macName)
                    .transition(.opacity)
            }

            VStack {
                if model.isShowingPill || model.phase == .connecting {
                    pill
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
                if model.showsControls {
                    MobileMirrorControls(model: model, numbered: model.guide == .controls)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            if model.guide == .gesture {
                MobileMirrorGestureGuide(voiceOver: voiceOver) { model.finishGuide() }
                    .transition(.opacity)
            } else if model.guide == .controls {
                VStack {
                    MobileMirrorControlsGuide { model.finishGuide() }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.isShowingPill)
        .animation(.easeOut(duration: 0.2), value: model.showsControls)
        .animation(.easeOut(duration: 0.25), value: model.guide)
        .animation(.easeOut(duration: 0.4), value: model.isStandby)
        .environment(\.colorScheme, .dark)
    }

    private var pill: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.phase == .live ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(verbatim: [model.macName, model.sourceTitle].compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1)
            }
            .font(.footnote.weight(.medium))
            if model.pillReminds {
                Text("two fingers · controls")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(MobileMirrorChrome.plate, in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func statusCard(_ message: String, showsEnd: Bool) -> some View {
        VStack(spacing: 14) {
            Text(verbatim: message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            if showsEnd {
                Button(MobileL10n.string("End Mirror")) { model.end() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .padding(22)
        .background(MobileMirrorChrome.plate, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(32)
    }
}

/// The stage's chrome sits over pages of any colour, so its glass always has a dark plate in it.
private enum MobileMirrorChrome {
    static let plate = Color(white: 0.08).opacity(0.72)
}

/// The capsule: source, the three actions that matter while looking, **?** and **End Mirror**.
private struct MobileMirrorControls: View {
    @ObservedObject var model: MobileMirrorStageModel
    let numbered: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text(verbatim: model.macName + (model.revision > 0 ? " · v\(model.revision)" : ""))
                    .lineLimit(1)
                Spacer()
                Button {
                    model.replayGuide()
                } label: {
                    Image(systemName: "questionmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel(MobileL10n.string("Show the controls guide"))
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.75))

            HStack(spacing: 6) {
                control("arrow.clockwise", MobileL10n.string("Reload"), isOn: false, badge: 2) { model.reload() }
                control(
                    model.mode == .viewOnly ? "eye" : "hand.tap",
                    model.mode == .viewOnly ? MobileL10n.string("View Only") : MobileL10n.string("Interactive"),
                    isOn: model.mode != .viewOnly,
                    badge: 3
                ) { model.toggleMode() }
                control(
                    model.isRotationLocked ? "lock.rotation" : "rotate.right",
                    MobileL10n.string("Lock Rotation"),
                    isOn: model.isRotationLocked
                ) { model.toggleRotationLock() }
            }

            Button {
                model.end()
            } label: {
                Text("End Mirror")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Color(red: 1, green: 0.54, blue: 0.5))
                    .overlay(alignment: .topTrailing) { badge(1) }
            }
        }
        .padding(10)
        .background(MobileMirrorChrome.plate, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .simultaneousGesture(TapGesture().onEnded { model.scheduleControlsHide() })
    }

    private func control(
        _ symbol: String, _ title: String, isOn: Bool, badge number: Int? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.body)
                Text(verbatim: title).font(.caption2).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                isOn ? Color.blue.opacity(0.28) : Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(alignment: .topTrailing) { if let number { badge(number) } }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder
    private func badge(_ number: Int) -> some View {
        if numbered {
            Text(verbatim: "\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Color.blue, in: Circle())
                .offset(x: 4, y: -5)
                .accessibilityHidden(true)
        }
    }
}

/// Step 1: hold two fingers. It advances only when the person does it.
private struct MobileMirrorGestureGuide: View {
    let voiceOver: Bool
    let onSkip: () -> Void
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.8)).ignoresSafeArea()
            VStack(spacing: 0) {
                Text("1 of 2")
                    .font(.caption2)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 40)
                Spacer()
                ZStack {
                    finger.offset(x: -22, y: -4)
                    finger.offset(x: 22, y: 6)
                }
                .frame(width: 96, height: 70)
                .accessibilityHidden(true)
                Text(verbatim: voiceOver
                    ? MobileL10n.string("Scrub two fingers to bring up the controls")
                    : MobileL10n.string("Hold two fingers on the screen"))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                Text("That brings up the controls. Try it now.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                Spacer()
                Button(MobileL10n.string("Skip"), action: onSkip)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 28)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pressed = true }
        }
    }

    private var finger: some View {
        Circle()
            .fill(Color.blue.opacity(0.28))
            .overlay(Circle().stroke(Color.blue, lineWidth: 2))
            .frame(width: 36, height: 36)
            .scaleEffect(pressed ? 0.88 : 1)
            .shadow(color: .blue.opacity(pressed ? 0.35 : 0), radius: pressed ? 10 : 0)
    }
}

/// Step 2: the real capsule, with three numbered things worth knowing.
private struct MobileMirrorControlsGuide: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("These are the controls")
                .font(.headline)
            row(1, "End whenever you like")
            row(2, "Reload what the Mac shows")
            row(3, "Interactive or view only")
            Text("You can also end it from the Mac or the Lock Screen.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 2)
            Button(action: onDone) {
                Text("Got It")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(MobileMirrorChrome.plate, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func row(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.caption2.weight(.bold))
                .frame(width: 16, height: 16)
                .background(Color.blue, in: Circle())
                .accessibilityHidden(true)
            Text(text).font(.subheadline)
        }
    }
}

/// The stage at rest: black, the Mac's name, a slow breath. The idle timer is back on.
private struct MobileMirrorStandby: View {
    let macName: String
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 4) {
                Circle()
                    .stroke(Color.blue.opacity(0.6), lineWidth: 2)
                    .frame(width: 92, height: 92)
                    .shadow(color: .blue.opacity(0.35), radius: 20)
                    .scaleEffect(breathing ? 1.04 : 0.92)
                    .opacity(breathing ? 1 : 0.7)
                    .padding(.bottom, 18)
                    .accessibilityHidden(true)
                Text("Ready for mirroring").font(.headline)
                Text(verbatim: macName).font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { breathing = true }
        }
    }
}

// MARK: - The quiet offer

/// *Mirror ready · Show*, at the top of the app while the phone is in use. It takes no focus,
/// plays no haptic and sits above the screen's own chrome, never over the composer.
struct MobileMirrorOfferPill: View {
    let macName: String
    let onShow: () -> Void

    var body: some View {
        Button(action: onShow) {
            HStack(spacing: 6) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                Text("Mirror ready · Show")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MobileL10n.string("Mirror from %@ is ready. Show it.", macName))
    }
}

/// Places the quiet offer over the app's own window, without taking it from the person.
@MainActor
final class MobileMirrorOfferPresenter {
    var onShow: (() -> Void)?
    private var host: UIHostingController<AnyView>?

    func present(macName: String, theme: RemoteThemePalette?) {
        dismiss()
        guard let window = MobileInteractionMonitor.shared.appWindow else { return }
        let pill = MobileMirrorOfferPill(macName: macName) { [weak self] in self?.onShow?() }
        let root: AnyView = theme.map { AnyView(pill.mobileTheme($0)) } ?? AnyView(pill)
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            // Below a screen's own navigation bar, floating over its content like a jump-to-latest
            // pill: never over the header's controls and never near the composer.
            host.view.topAnchor.constraint(
                equalTo: window.safeAreaLayoutGuide.topAnchor, constant: MobileMirrorDefaults.offerTopInset
            ),
        ])
        host.view.alpha = 0
        UIView.animate(withDuration: 0.25) { host.view.alpha = 1 }
        self.host = host
    }

    func dismiss() {
        guard let host else { return }
        self.host = nil
        UIView.animate(withDuration: 0.2, animations: { host.view.alpha = 0 }, completion: { _ in
            host.view.removeFromSuperview()
        })
    }
}
