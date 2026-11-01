import Foundation

/// What a host without the Mac interface shows of the store at one moment, as the JSON a separate interface reads: the
/// Windows shell runs `agenthud-core --watch` and reads one of these per line. Names, countdowns and amounts are already
/// in words, in the settings' language, so that interface only lays them out. `version` changes when a field changes
/// meaning or goes away; new fields may appear without it.
public struct HeadlessSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Row: Codable, Equatable, Sendable {
        public let id: String
        public let vendor: String
        public let vendorName: String
        public let name: String
        public let shortName: String
        /// Share of the window used, 0 to 100; nil when the window has no reading.
        public let usedPct: Double?
        public let weeklyUsedPct: Double?
        public let resetAt: Date?
        public let resetLabel: String
        /// `ok`, `warning` or `critical`; nil when the row shows no level, such as another account's.
        public let level: String?
        public let paletteIndex: Int
        public let isCurrentAccount: Bool
    }

    public struct Session: Codable, Equatable, Sendable {
        public let id: String
        public let agentId: String
        public let vendor: String?
        public let title: String
        public let client: String?
        public let project: String?
        public let status: String
        public let isLive: Bool
        public let isWaiting: Bool
        public let tokensIn: Int
        public let tokensOut: Int
        public let startedAt: Date
        public let observedAt: Date
    }

    public struct Billing: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let balances: [String]
    }

    public let version: Int
    public let generatedAt: Date
    public let language: String
    public let rows: [Row]
    public let sessions: [Session]
    public let billing: [Billing]
    /// The highest share used among the current account's windows, which colours the glow.
    public let maxUsedPct: Double?
    /// The worst level among the rows; nil while nothing has a level.
    public let level: String?
    /// The vendors with a session at work now.
    public let workingVendors: [String]
    public let isLoading: Bool
    public let error: String?
}

extension HeadlessSnapshot {
    /// The store as it reads now.
    @MainActor
    public static func make(store: UsageStore, now: Date = Date()) -> HeadlessSnapshot {
        let view = store.view
        let rows = view.rows.map { row in
            Row(id: row.id, vendor: row.agent.displayVendor, vendorName: row.agent.vendorName, name: row.agent.name,
                shortName: row.agent.shortName, usedPct: row.usedPct,
                weeklyUsedPct: row.weeklyRemainingPct.map { max(0, min(100, 100 - $0)) }, resetAt: row.resetAt,
                resetLabel: row.resetLabel(now: now), level: row.level?.rawValue, paletteIndex: row.paletteIndex,
                isCurrentAccount: row.isCurrentAccount)
        }
        let agents = Dictionary(store.settings.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sessions = store.sessions.map { session in
            Session(id: session.id, agentId: session.agentId, vendor: agents[session.agentId]?.displayVendor, title: session.task,
                    client: session.client, project: session.terminal, status: store.sessionStatusLabel(session),
                    isLive: store.isSessionLive(session), isWaiting: store.isSessionWaiting(session),
                    tokensIn: session.tokensIn, tokensOut: session.tokensOut, startedAt: session.startedAt,
                    observedAt: session.observedAt)
        }
        let billing = store.enabledBilling.map { account in
            Billing(id: account.id, name: account.displayName,
                    balances: account.balances.map { MoneyFormat.amount($0.total, currency: $0.currency) })
        }
        let levels = view.levels
        let level: StatusLevel? = levels.contains(.critical) ? .critical : levels.contains(.warning) ? .warning
            : levels.isEmpty ? nil : .ok
        return HeadlessSnapshot(version: currentVersion, generatedAt: store.dataDate, language: L10n.resolved == .zhHans ? "zh" : "en",
                                rows: rows, sessions: sessions, billing: billing, maxUsedPct: store.maxUsedPct,
                                level: level?.rawValue, workingVendors: store.workingVendors.sorted(),
                                isLoading: store.isLoading, error: store.lastError)
    }

    /// One line of JSON, dates in ISO 8601, keys sorted.
    public func line() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
