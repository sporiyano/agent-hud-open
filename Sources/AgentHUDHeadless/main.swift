import Foundation
import AgentHUDCore

// `agenthud-core`: Core without an interface, for hosts that draw their own, such as the Windows shell. It answers the
// same hook and adapter commands as the application, and:
//
//   --probe    prints what one read finds, as the application's `--probe` does
//   --report   reads once and prints one snapshot (`HeadlessSnapshot`) as a line of JSON
//   --watch    keeps reading as the application does and prints a snapshot line after every pass; it quits when its
//              standard input closes, so it never outlives the interface that started it
//   --lang zh|en|system   the language of names and countdowns in the snapshots

let arguments = CommandLine.arguments

if let status = HookEntry.handle(arguments: arguments) { exit(status) }

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func language() -> AppLanguage? {
    switch value(after: "--lang")?.lowercased() {
    case "zh", "zh-hans", "cn": return .zhHans
    case "en": return .en
    case "system": return .system
    default: return nil
    }
}

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@MainActor
enum Watching {
    /// Keeps the lock for as long as the process runs.
    static var instanceLock: InstanceLock?
    /// The store `--watch` runs.
    static var store: UsageStore?
}

@MainActor
func report(settings: SettingsStore) async -> Int32 {
    let provider = CombinedUsageProvider.standard(settings: settings, ledger: .inMemory(), persistent: false)
    await provider.refreshAccountUsage(historyHours: UsageProbe.historyHours)
    do {
        let report = try await provider.fetchUsage(agents: settings.agents, historyHours: UsageProbe.historyHours)
        let store = UsageStore(provider: provider, settings: settings)
        store.replace(report: report)
        emit(HeadlessSnapshot.make(store: store).line())
        return 0
    } catch {
        fail("Reading failed: \(error.localizedDescription)")
    }
}

@MainActor
func watch(settings: SettingsStore) {
    switch InstanceLock.claim(at: InstanceLock.sharedURL, executable: URL(fileURLWithPath: CommandLine.arguments[0])) {
    case .acquired(let lock): Watching.instanceLock = lock
    case .unavailable: break
    case .held(let holder): fail("Agent HUD is already running" + (holder.map { ": \($0.path)" } ?? "."))
    }
    let hooks = UsageCollectionHooks(afterPass: { _ in
        if let store = Watching.store { emit(HeadlessSnapshot.make(store: store).line()) }
    })
    let store = UsageAssembly.store(settings: settings, ledger: .open(), hooks: hooks)
    Watching.store = store
    if store.report != nil { emit(HeadlessSnapshot.make(store: store).line()) }
    store.start()
    // The interface holds the other end of standard input: a `refresh` line reads the accounts again, and when the
    // interface goes, so does this.
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) {
            if line == "refresh" { Task { @MainActor in await Watching.store?.refreshAccounts() } }
        }
        exit(0)
    }
}

let settings = UsageAssembly.settings(language: language())

if arguments.contains("--probe") {
    Task { @MainActor in exit(await UsageProbe.run(settings: settings)) }
} else if arguments.contains("--report") {
    Task { @MainActor in exit(await report(settings: settings)) }
} else if arguments.contains("--watch") {
    watch(settings: settings)
} else {
    fail("Usage: agenthud-core --watch | --report | --probe [--lang zh|en|system]")
}
dispatchMain()
