#if os(Windows)
import Foundation
import WinSDK

/// What Windows tells this user about its processes: each one's parent, executable, arguments and start time. A
/// process id is reused once its process ends, so a parent counts only when it started before its child.
enum WindowsProcesses {
    struct Process: Sendable {
        let pid: DWORD
        let executable: String
        let arguments: [String]
        let started: UInt64
    }

    /// Every process's parent, from one snapshot.
    static func parents() -> [DWORD: DWORD] {
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard let snapshot, snapshot != INVALID_HANDLE_VALUE else { return [:] }
        defer { CloseHandle(snapshot) }
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var result: [DWORD: DWORD] = [:]
        guard Bool(Process32FirstW(snapshot, &entry)) else { return [:] }
        repeat {
            result[entry.th32ProcessID] = entry.th32ParentProcessID
        } while Bool(Process32NextW(snapshot, &entry))
        return result
    }

    /// The process `pid`, when this user may look at it.
    static func process(_ pid: DWORD) -> Process? {
        guard pid > 4, let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return nil }
        defer { CloseHandle(handle) }
        guard let executable = executable(handle), let started = started(handle) else { return nil }
        let arguments = commandLine(handle).map(WindowsCommandLine.arguments) ?? []
        return Process(pid: pid, executable: executable, arguments: arguments, started: started)
    }

    private static func executable(_ handle: HANDLE) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 32 * 1024)
        var size = DWORD(buffer.count)
        guard Bool(QueryFullProcessImageNameW(handle, 0, &buffer, &size)), size > 0 else { return nil }
        return String(decoding: buffer[..<Int(size)], as: UTF16.self)
    }

    private static func started(_ handle: HANDLE) -> UInt64? {
        var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard Bool(GetProcessTimes(handle, &creation, &exit, &kernel, &user)) else { return nil }
        return UInt64(creation.dwHighDateTime) << 32 | UInt64(creation.dwLowDateTime)
    }

    private typealias QueryInformation = @convention(c) (
        HANDLE?, Int32, UnsafeMutableRawPointer?, ULONG, UnsafeMutablePointer<ULONG>?
    ) -> Int32

    /// `NtQueryInformationProcess`, which has no import library in the SDK, found in ntdll at run time.
    private static let queryInformation: QueryInformation? = {
        guard let ntdll = "ntdll.dll".withCString(encodedAs: UTF16.self, { GetModuleHandleW($0) }),
              let address = GetProcAddress(ntdll, "NtQueryInformationProcess") else { return nil }
        return unsafeBitCast(address, to: QueryInformation.self)
    }()

    /// The process's command line, read with ProcessCommandLineInformation (Windows 8.1 and later). The answer is a
    /// UNICODE_STRING, whose text follows it in the same buffer.
    private static func commandLine(_ handle: HANDLE) -> String? {
        guard let query = queryInformation else { return nil }
        let processCommandLineInformation: Int32 = 60
        var needed: ULONG = 0
        _ = query(handle, processCommandLineInformation, nil, 0, &needed)
        guard needed > 0, needed <= 1024 * 1024 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(needed), alignment: 16)
        defer { buffer.deallocate() }
        guard query(handle, processCommandLineInformation, buffer, needed, &needed) >= 0 else { return nil }
        let length = Int(buffer.load(as: UInt16.self)) / 2
        let text = buffer.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UnsafePointer<UInt16>?.self)
        guard let text, length > 0 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF16.self)
    }
}
#endif
