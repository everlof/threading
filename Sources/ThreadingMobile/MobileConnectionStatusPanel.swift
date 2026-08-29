import SwiftUI
import ThreadingRemoteKit
import UIKit
import UniformTypeIdentifiers

// MARK: - What the phone knows

/// The route this phone last reached a Mac over.
///
/// The connect flow records this beside the catalogue rather than deriving it later, because the
/// facts a person asks for when a chat feels slow — which way in answered, at what address, over
/// which network, and how long TLS took — are known exactly once, in the attempt that succeeded,
/// and the diagnostics journal deliberately reduces them to hashed tokens. This value stays on
/// the phone: it is what the connection panel shows, and nothing uploads it.
struct MobileConnectionRecord: Equatable, Sendable {
    let hostID: String
    let kind: RemoteHostEndpointKind
    /// Scheme, host and port. Never the link: the pairing bearer lives in the link and has no
    /// business in a panel or on the pasteboard.
    let baseURL: URL
    let isHosted: Bool
    let connectedAt: Date
    let metrics: RemoteRequestMetrics?
    let serverProtocol: RemoteProtocolInfo?
}

/// An address the way a person reads it: `192.168.1.42:8760`, `[fd00::1]:8760`, or a name.
enum MobileConnectionAddressFormat {
    static func display(_ url: URL) -> String {
        // Fail closed: a malformed origin must not make its path, query, fragment, or user-info
        // visible in the panel or its copy. Valid connection links always have a host.
        guard let host = url.host, !host.isEmpty else { return "—" }
        let shown = host.contains(":") ? "[\(host)]" : host
        guard let port = url.port else { return shown }
        return "\(shown):\(port)"
    }
}

/// Writes connection details without handing private-network addresses to Universal Clipboard.
///
/// A person explicitly asked for a copy, so the text remains on this phone's pasteboard until
/// they replace it. `localOnly` is the security boundary: a default pasteboard item may travel to
/// another signed-in Apple device, contradicting the panel's promise that these addresses stay
/// on the iPhone.
@MainActor
enum MobileConnectionPasteboard {
    /// Computed rather than stored: a stored `[OptionsKey: Any]` is shared mutable state to the
    /// compiler, and this is the one policy value, not a cache.
    static var options: [UIPasteboard.OptionsKey: Any] { [.localOnly: true] }

    static func write(_ text: String, to pasteboard: UIPasteboard = .general) {
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: options
        )
    }
}

// MARK: - The report

/// Everything the connection panel says, as rows of words.
///
/// A value rather than a view reading the model, because what is worth asserting is which facts
/// appear for a given connection state and that none of them is a credential. The panel draws
/// this; the tests read it.
struct MobileConnectionReport: Equatable {
    enum Tone: Equatable {
        case neutral
        case positive
        case warning
        case negative
    }

    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let value: String
        var tone: Tone = .neutral
    }

    struct Card: Equatable, Identifiable {
        let id: String
        let title: String
        let rows: [Row]
        var footer: String? = nil
    }

    let headline: String
    let detail: String?
    let tone: Tone
    let sections: [Card]
    /// Whether there is a Mac for **Check connection** to try.
    let canCheck: Bool

    /// A Mac advertises a handful of ways in and the policy admits fewer; the list is bounded
    /// here all the same so a host payload cannot decide how long this panel is.
    static let maximumWayInRows = 8
    /// The first token of `RemoteRequestMetrics.networkPath` when the request went over cellular.
    private static let cellularPathPrefix = "cellular"

    /// The report as plain lines, for the pasteboard. Same words as the panel, nothing more:
    /// in particular no link, no bearer, no fingerprint hex.
    var copyText: String {
        var lines = [headline]
        if let detail { lines.append(detail) }
        for section in sections {
            lines.append("")
            lines.append(section.title)
            for row in section.rows {
                lines.append("\(row.title): \(row.value.replacingOccurrences(of: "\n", with: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func resolve(
        phase: RemoteAppModel.Phase,
        progress: RemoteAppModel.ConnectionProgress?,
        host: PairedRemoteHost?,
        record: MobileConnectionRecord?,
        discoveredAddress: URL?,
        path: MobileNetworkPathSummary?,
        interfaces: [MobileNetworkInterface],
        verdict: (String) -> RemoteTrustVerdict?,
        now: Date
    ) -> MobileConnectionReport {
        let phone = phoneSection(path: path, interfaces: interfaces)
        guard let host else {
            return MobileConnectionReport(
                headline: MobileL10n.string("Not connected to a Mac"),
                detail: nil,
                tone: .neutral,
                sections: [phone],
                canCheck: false
            )
        }

        let activeRecord = record.flatMap { $0.hostID == host.id ? $0 : nil }
        var isOnline = false
        if case .online = phase { isOnline = true }
        let routeKind = activeRecord?.kind
            ?? host.activeEndpointKind
            ?? PairedRemoteHost.endpointKind(for: host.link.baseURL)
        let routeLabel = PairedRemoteHost.connectionLabel(forEndpointKind: routeKind)
        let routeURL = activeRecord?.baseURL ?? host.link.baseURL
        let hostedInUse = isOnline && activeRecord?.isHosted == true

        let headline: String
        let detail: String?
        let tone: Tone
        switch phase {
        case .online:
            headline = MobileL10n.string("Connected over %@", routeLabel)
            detail = host.name
            tone = .positive
        case .connecting:
            headline = MobileDashboardChrome.connectionStatus(
                phase: .connecting,
                connectionLabel: nil,
                progress: progress
            )
            detail = host.name
            tone = .warning
        case .idle:
            headline = MobileL10n.string("Not connected")
            detail = host.name
            tone = .neutral
        case .offline(let failure):
            if case .waitingToRetry = progress {
                headline = MobileL10n.string("Trying again…")
                tone = .warning
            } else {
                headline = MobileL10n.string("Not connected")
                tone = .negative
            }
            detail = failure.message
        }

        return MobileConnectionReport(
            headline: headline,
            detail: detail,
            tone: tone,
            sections: [
                macSection(
                    host: host,
                    phase: phase,
                    isOnline: isOnline,
                    routeLabel: routeLabel,
                    routeURL: routeURL,
                    hostedInUse: hostedInUse,
                    record: activeRecord,
                    verdict: verdict
                ),
                requestSection(record: activeRecord),
                waysInSection(
                    host: host,
                    isOnline: isOnline,
                    activeURL: isOnline ? routeURL : nil,
                    hostedInUse: hostedInUse,
                    discoveredAddress: discoveredAddress
                ),
                phone,
            ].compactMap { $0 },
            canCheck: true
        )
    }

    // MARK: Sections

    private static func macSection(
        host: PairedRemoteHost,
        phase: RemoteAppModel.Phase,
        isOnline: Bool,
        routeLabel: String,
        routeURL: URL,
        hostedInUse: Bool,
        record: MobileConnectionRecord?,
        verdict: (String) -> RemoteTrustVerdict?
    ) -> Card {
        var rows: [Row] = [Row(id: "mac", title: MobileL10n.string("Mac"), value: host.name)]

        let status: (String, Tone)
        switch phase {
        case .online: status = (MobileL10n.string("Connected"), .positive)
        case .connecting: status = (MobileL10n.string("Connecting"), .warning)
        case .idle: status = (MobileL10n.string("Idle"), .neutral)
        case .offline: status = (MobileL10n.string("Not connected"), .negative)
        }
        rows.append(Row(
            id: "status",
            title: MobileL10n.string("Status"),
            value: status.0,
            tone: status.1
        ))

        rows.append(Row(
            id: "route",
            title: MobileL10n.string(isOnline ? "Way in" : "Last way in"),
            value: routeLabel
        ))
        rows.append(Row(
            id: "address",
            title: MobileL10n.string(isOnline ? "Address" : "Last used address"),
            value: hostedInUse
                ? MobileL10n.string("Through Threading’s service")
                : MobileConnectionAddressFormat.display(routeURL)
        ))

        if isOnline, let record {
            rows.append(Row(
                id: "since",
                title: MobileL10n.string("Connected"),
                value: record.connectedAt.formatted(date: .omitted, time: .shortened)
            ))
        } else {
            rows.append(Row(
                id: "since",
                title: MobileL10n.string("Last connected"),
                value: host.lastConnectedAt.formatted(date: .abbreviated, time: .shortened)
            ))
        }

        let identity: (String, Tone)
        switch routeURL.host.map({ $0.lowercased() }).flatMap(verdict) {
        case .accepted:
            identity = (MobileL10n.string("Pinned and verified"), .positive)
        case .rejectedFingerprintMismatch:
            identity = (MobileL10n.string("Refused: certificate mismatch"), .negative)
        case .notPinned:
            identity = (MobileL10n.string("Not pinned, system trust"), .neutral)
        case nil:
            identity = host.pinSet != nil
                ? (MobileL10n.string("Pinned, not checked yet"), .neutral)
                : (MobileL10n.string("Not pinned"), .warning)
        }
        rows.append(Row(
            id: "identity",
            title: MobileL10n.string("Identity"),
            value: identity.0,
            tone: identity.1
        ))
        if let code = host.pinnedFingerprintCode {
            rows.append(Row(id: "identity-code", title: MobileL10n.string("Identity code"), value: code))
        }

        if let server = record?.serverProtocol {
            rows.append(Row(
                id: "protocol",
                title: MobileL10n.string("Remote protocol"),
                value: MobileL10n.string(
                    "%lld · this app %lld",
                    Int64(server.version),
                    Int64(RemoteProtocol.current)
                )
            ))
        }

        return Card(id: "mac", title: MobileL10n.string("This Mac"), rows: rows)
    }

    private static func requestSection(record: MobileConnectionRecord?) -> Card? {
        guard let metrics = record?.metrics else { return nil }
        var rows: [Row] = []
        if let token = metrics.networkProtocol {
            rows.append(Row(
                id: "protocol",
                title: MobileL10n.string("Protocol"),
                value: protocolName(token)
            ))
        }
        let overCellular = metrics.networkPath.hasPrefix(Self.cellularPathPrefix)
        rows.append(Row(
            id: "cellular",
            title: MobileL10n.string("Over cellular"),
            value: MobileL10n.string(overCellular ? "Yes" : "No")
        ))
        rows.append(Row(
            id: "reused",
            title: MobileL10n.string("Connection reused"),
            value: MobileL10n.string(metrics.connectionReused ? "Yes" : "No")
        ))
        let timings: [(id: String, title: String, value: Int?)] = [
            ("dns", MobileL10n.string("DNS"), metrics.dnsMS),
            ("tcp", MobileL10n.string("TCP"), metrics.tcpMS),
            ("tls", MobileL10n.string("TLS"), metrics.tlsMS),
            ("server", MobileL10n.string("Server wait"), metrics.serverWaitMS),
        ]
        for timing in timings {
            guard let value = timing.value else { continue }
            rows.append(Row(
                id: timing.id,
                title: timing.title,
                value: MobileL10n.string("%lld ms", Int64(value))
            ))
        }
        return Card(id: "request", title: MobileL10n.string("Last request"), rows: rows)
    }

    private static func waysInSection(
        host: PairedRemoteHost,
        isOnline: Bool,
        activeURL: URL?,
        hostedInUse: Bool,
        discoveredAddress: URL?
    ) -> Card? {
        let inUse = MobileL10n.string("In use")
        let activeAddress = activeURL.map(MobileConnectionAddressFormat.display)
        var rows: [Row] = []

        if host.hostedCredential != nil, host.hostedServiceURL != nil {
            rows.append(Row(
                id: "hosted",
                title: PairedRemoteHost.connectionLabel(forEndpointKind: .hosted),
                value: hostedInUse
                    ? "\(MobileL10n.string("Through Threading’s service")) · \(inUse)"
                    : MobileL10n.string("Through Threading’s service"),
                tone: hostedInUse ? .positive : .neutral
            ))
        }

        if let discoveredAddress {
            let address = MobileConnectionAddressFormat.display(discoveredAddress)
            let active = !hostedInUse && activeAddress == address
            rows.append(Row(
                id: "discovered",
                title: MobileL10n.string("Found on this network"),
                value: active ? "\(address) · \(inUse)" : address,
                tone: .positive
            ))
        }

        let advertised: [(kind: RemoteHostEndpointKind, url: URL, isStable: Bool)]
        if let endpoints = host.endpoints {
            advertised = RemoteHostEndpointSelection.ordered(
                endpoints,
                policy: host.connectionPolicy ?? .privateOnly,
                currentBaseURL: host.link.baseURL
            ).map { ($0.kind, $0.baseURL, $0.isStable) }
        } else {
            advertised = [(
                PairedRemoteHost.endpointKind(for: host.link.baseURL),
                host.link.baseURL,
                true
            )]
        }
        for (index, entry) in advertised.prefix(maximumWayInRows).enumerated() {
            let address = MobileConnectionAddressFormat.display(entry.url)
            let active = !hostedInUse && activeAddress == address
                && discoveredAddress.map(MobileConnectionAddressFormat.display) != address
            var parts = [address]
            if !entry.isStable { parts.append(MobileL10n.string("Temporary")) }
            if active { parts.append(inUse) }
            rows.append(Row(
                id: "endpoint-\(index)",
                title: PairedRemoteHost.connectionLabel(forEndpointKind: entry.kind),
                value: parts.joined(separator: " · "),
                tone: active ? .positive : .neutral
            ))
        }

        guard !rows.isEmpty else { return nil }
        return Card(
            id: "routes",
            title: MobileL10n.string("Ways in"),
            rows: rows,
            footer: MobileL10n.string("Tried in this order until one answers.")
        )
    }

    private static func phoneSection(
        path: MobileNetworkPathSummary?,
        interfaces: [MobileNetworkInterface]
    ) -> Card {
        var rows: [Row] = [Row(
            id: "network",
            title: MobileL10n.string("Network"),
            value: networkDescription(path),
            tone: path?.status == .satisfied ? .neutral : .warning
        )]
        for interface in interfaces {
            rows.append(Row(
                id: "interface-\(interface.name)",
                title: MobileL10n.string("%@ (%@)", kindLabel(interface.kind), interface.name),
                value: interface.addresses.isEmpty
                    ? MobileL10n.string("No addresses")
                    : interface.addresses.joined(separator: "\n")
            ))
        }
        return Card(
            id: "phone",
            title: MobileL10n.string("This iPhone"),
            rows: rows,
            footer: MobileL10n.string(
                "Addresses stay on this iPhone. Copy details puts these words on the clipboard and never includes the pairing credential."
            )
        )
    }

    // MARK: Words

    private static func networkDescription(_ path: MobileNetworkPathSummary?) -> String {
        guard let path else { return MobileL10n.string("Checking…") }
        switch path.status {
        case .unsatisfied, .requiresConnection:
            return MobileL10n.string("No network")
        case .satisfied:
            var parts: [String] = []
            if path.usesWiFi { parts.append(MobileL10n.string("Wi-Fi")) }
            if path.usesCellular { parts.append(MobileL10n.string("Cellular")) }
            if path.usesWired { parts.append(MobileL10n.string("Ethernet")) }
            if parts.isEmpty { parts.append(MobileL10n.string("VPN or other")) }
            if path.isConstrained { parts.append(MobileL10n.string("Low Data Mode")) }
            return parts.joined(separator: ", ")
        }
    }

    static func kindLabel(_ kind: MobileNetworkInterface.Kind) -> String {
        switch kind {
        case .wifi: return MobileL10n.string("Wi-Fi")
        case .cellular: return MobileL10n.string("Cellular")
        case .vpn: return MobileL10n.string("VPN")
        case .wired: return MobileL10n.string("Ethernet")
        }
    }

    /// The wire token back into the name a person knows. Not localized: a protocol's name is
    /// the same in every language.
    private static func protocolName(_ token: String) -> String {
        switch token {
        case "h2": return "HTTP/2"
        case "h3": return "HTTP/3"
        case "http1.1": return "HTTP/1.1"
        case "http1.0": return "HTTP/1.0"
        default: return MobileL10n.string("Other")
        }
    }
}

// MARK: - The panel

/// The connection panel's content: the report drawn on the mobile settings vocabulary, and the
/// two things a person can do from it.
///
/// Separate from the sheet so the DEBUG fixture and the evidence capture can render the exact
/// shipping hierarchy from a fixture report, and so the sheet stays the one place that reads the
/// live model.
struct MobileConnectionStatusContent: View {
    let report: MobileConnectionReport
    let isChecking: Bool
    let check: () -> Void
    let copy: () -> Void

    @Environment(\.remoteTheme) private var theme
    @State private var justCopied = false

    private static let copiedAcknowledgement: Duration = .seconds(1.5)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileDesign.Spacing.pane) {
                headlineCard
                ForEach(report.sections) { section in
                    sectionView(section)
                }
                actions
            }
            .padding(.horizontal, MobileDesign.Spacing.inset)
            .padding(.top, MobileDesign.Spacing.medium)
            .padding(.bottom, MobileDesign.Spacing.pane)
        }
        .background(theme.ground)
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var headlineCard: some View {
        ThemedRowGroup {
            HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.small) {
                Circle()
                    .fill(color(for: report.tone, resting: theme.tertiaryLabel))
                    .frame(
                        width: MobileDesign.Size.rowAttentionDot,
                        height: MobileDesign.Size.rowAttentionDot
                    )
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                    Text(report.headline)
                        .font(.headline)
                        .foregroundStyle(theme.label)
                    if let detail = report.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(MobileDesign.Spacing.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func sectionView(_ section: MobileConnectionReport.Card) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Text(section.title)
                .font(.headline)
                .foregroundStyle(theme.label)
                .padding(.horizontal, MobileDesign.Spacing.inset)
            ThemedRowGroup {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { ThemedRowDivider() }
                    rowView(row)
                }
            }
            if let footer = section.footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
                    .padding(.horizontal, MobileDesign.Spacing.inset)
            }
        }
    }

    private func rowView(_ row: MobileConnectionReport.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.medium) {
            Text(row.title)
                .foregroundStyle(theme.label)
            Spacer(minLength: MobileDesign.Spacing.small)
            Text(row.value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(color(for: row.tone, resting: theme.secondaryLabel))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, MobileDesign.Spacing.inset)
        .padding(.vertical, MobileDesign.Spacing.small)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        ThemedRowGroup {
            Button(action: check) {
                HStack(spacing: MobileDesign.Spacing.small) {
                    if isChecking {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                    } else {
                        Image(systemName: "stethoscope")
                        Text("Check connection")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, MobileDesign.Spacing.inset)
                .padding(.vertical, MobileDesign.Spacing.medium)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(report.canCheck ? theme.accent : theme.tertiaryLabel)
            .disabled(!report.canCheck || isChecking)

            ThemedRowDivider()

            Button {
                copy()
                justCopied = true
                Task {
                    try? await Task.sleep(for: Self.copiedAcknowledgement)
                    justCopied = false
                }
            } label: {
                HStack(spacing: MobileDesign.Spacing.small) {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    Text(justCopied ? MobileL10n.string("Copied") : MobileL10n.string("Copy details"))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, MobileDesign.Spacing.inset)
                .padding(.vertical, MobileDesign.Spacing.medium)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
        }
    }

    private func color(for tone: MobileConnectionReport.Tone, resting: Color) -> Color {
        switch tone {
        case .neutral: return resting
        case .positive: return theme.positive
        case .warning: return theme.warning
        case .negative: return theme.negative
        }
    }
}

/// The connection panel as it is presented: over the current screen, reading the live model.
struct MobileConnectionStatusSheet: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var network = MobileNetworkPathObserver()
    @State private var isChecking = false

    var body: some View {
        NavigationStack {
            MobileConnectionStatusContent(
                report: report,
                isChecking: isChecking,
                check: {
                    isChecking = true
                    Task {
                        await model.refresh()
                        isChecking = false
                    }
                },
                copy: { MobileConnectionPasteboard.write(report.copyText) }
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await network.run() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var report: MobileConnectionReport {
        MobileConnectionReport.resolve(
            phase: model.phase,
            progress: model.connectionProgress,
            host: model.activeHost,
            record: model.lastConnection,
            discoveredAddress: model.activeHostID.flatMap(model.discoveredAddress(forHostID:)),
            path: network.path,
            interfaces: network.interfaces,
            verdict: RemoteHostTrust.liveVerdict,
            now: Date()
        )
    }
}

/// The navigation title that opens the connection panel when tapped.
///
/// One control for every screen whose principal item is the two-line connection title — the
/// chat list, a project's chat list, an open chat and a new-session draft — so tapping the words
/// that say "Connected · Tailscale" answers the question they raise in the same place on every
/// screen. Screens keep `MobileConnectionNavigationTitle` itself only where the tap already
/// means something else, such as an open chat's failure recovery.
struct MobileConnectionStatusButton: View {
    let title: String
    let status: String
    let statusColor: Color

    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            MobileConnectionNavigationTitle(
                title: title,
                status: status,
                statusColor: statusColor
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(MobileL10n.string("Shows how this iPhone reaches the Mac"))
        .sheet(isPresented: $isPresented) {
            MobileConnectionStatusSheet()
                .environmentObject(model)
                .mobileTheme(theme)
        }
    }
}

// MARK: - Fixtures

extension MobileConnectionRecord {
    /// A connection the demo Mac answered a moment ago over HTTP/2, with the timings a LAN
    /// answer has. Deterministic so the evidence capture photographs the same panel every run.
    /// Not DEBUG-only: the in-app demo ships, and its canned Mac is described with this.
    static func demo(hostID: String, baseURL: URL, kind: RemoteHostEndpointKind, now: Date) -> Self {
        let start = now.addingTimeInterval(-0.2)
        return MobileConnectionRecord(
            hostID: hostID,
            kind: kind,
            baseURL: baseURL,
            isHosted: false,
            connectedAt: now,
            metrics: RemoteRequestMetrics(
                domainLookupStart: start,
                domainLookupEnd: start.addingTimeInterval(0.012),
                connectStart: start.addingTimeInterval(0.012),
                connectEnd: start.addingTimeInterval(0.091),
                secureConnectionStart: start.addingTimeInterval(0.030),
                secureConnectionEnd: start.addingTimeInterval(0.091),
                requestStart: start.addingTimeInterval(0.092),
                requestEnd: start.addingTimeInterval(0.093),
                responseStart: start.addingTimeInterval(0.127),
                responseEnd: start.addingTimeInterval(0.130),
                networkProtocolName: "h2",
                isCellular: false,
                isExpensive: false,
                isConstrained: false,
                isMultipath: false,
                isReusedConnection: false
            ),
            serverProtocol: RemoteProtocolInfo()
        )
    }
}

#if DEBUG
extension MobileConnectionReport {
    /// The panel for the demo Mac, on a phone standing on Wi-Fi with a cellular context up.
    static func demo(host: PairedRemoteHost, record: MobileConnectionRecord?) -> Self {
        resolve(
            phase: .online,
            progress: nil,
            host: host,
            record: record,
            discoveredAddress: nil,
            path: MobileNetworkPathSummary(status: .satisfied, usesWiFi: true),
            interfaces: [
                MobileNetworkInterface(
                    name: "en0",
                    kind: .wifi,
                    ipv4: ["192.168.1.23"],
                    ipv6: ["fd12:3456:789a::1c2f"]
                ),
                MobileNetworkInterface(
                    name: "pdp_ip0",
                    kind: .cellular,
                    ipv4: ["10.212.44.7"],
                    ipv6: []
                ),
            ],
            verdict: { _ in .accepted },
            now: record?.connectedAt ?? Date()
        )
    }
}
#endif
