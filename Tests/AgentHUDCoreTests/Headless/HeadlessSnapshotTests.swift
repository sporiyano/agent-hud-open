import XCTest
@testable import AgentHUDCore

final class HeadlessSnapshotTests: XCTestCase {
    @MainActor
    func testTheSampleReadsAsRowsSessionsAndBalancesOnOneLineThatDecodesAgain() throws {
        let domain = "app.agenthud.tests.headless.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let now = Date()
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: now))

        let snapshot = HeadlessSnapshot.make(store: store, now: now)
        XCTAssertEqual(snapshot.version, HeadlessSnapshot.currentVersion)
        XCTAssertEqual(snapshot.language, "en")
        XCTAssertFalse(snapshot.rows.isEmpty)
        XCTAssertFalse(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.rows.allSatisfy { row in row.usedPct.map { (0...100).contains($0) } ?? true })
        XCTAssertTrue(snapshot.rows.contains { $0.vendor.lowercased() == "claude" })

        let line = snapshot.line()
        XCTAssertFalse(line.contains("\n"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HeadlessSnapshot.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.rows.map(\.id), snapshot.rows.map(\.id))
        XCTAssertEqual(decoded.sessions.map(\.id), snapshot.sessions.map(\.id))
    }
}
