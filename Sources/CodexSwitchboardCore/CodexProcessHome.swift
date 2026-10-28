import Darwin
import Foundation

public enum CodexHomeReading: Equatable {
    case unset
    case path(String)
    case unreadable
}

/// Reads only CODEX_HOME from a process's KERN_PROCARGS2 snapshot.
public enum CodexProcessHome {
    public static func parseProcArgs(_ bytes: [UInt8]) -> CodexHomeReading {
        guard bytes.count >= MemoryLayout<Int32>.size else { return .unreadable }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            destination.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        guard argc >= 0 else { return .unreadable }
        var offset = MemoryLayout<Int32>.size
        func nextString() -> ArraySlice<UInt8>? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return bytes[offset..<end]
        }
        guard nextString() != nil else { return .unreadable }
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        for _ in 0..<argc {
            guard nextString() != nil else { return .unreadable }
        }
        let prefix = Array("CODEX_HOME=".utf8)
        var values = Set<String>()
        while offset < bytes.count {
            // The final environment entry may end at the end of the snapshot.
            let end = bytes[offset...].firstIndex(of: 0) ?? bytes.count
            let entry = bytes[offset..<end]
            if entry.isEmpty { break }
            if entry.starts(with: prefix) {
                guard let value = String(bytes: entry.dropFirst(prefix.count), encoding: .utf8) else {
                    return .unreadable
                }
                values.insert(value)
            }
            offset = end + 1
        }
        guard values.count <= 1 else { return .unreadable }
        guard let value = values.first, !value.isEmpty else { return .unset }
        return .path(value)
    }

    public static func reading(pid: Int32) -> CodexHomeReading {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var sizeMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&sizeMIB, u_int(sizeMIB.count), &argmax, &size, nil, 0) == 0,
              argmax > 0 else { return .unreadable }
        var bytes = [UInt8](repeating: 0, count: Int(argmax))
        size = bytes.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = bytes.withUnsafeMutableBytes {
            sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0)
        }
        guard result == 0, size <= bytes.count else { return .unreadable }
        return parseProcArgs(Array(bytes.prefix(size)))
    }

    public static func usesOtherHome(_ reading: CodexHomeReading, surfaceHomes: [String]) -> Bool {
        guard !surfaceHomes.isEmpty, case let .path(path) = reading,
              path.hasPrefix("/"), !path.utf8.contains(0),
              let resolved = Darwin.realpath(path, nil) else { return false }
        defer { free(resolved) }
        let home = String(cString: resolved)
        return !surfaceHomes.contains { CodexLease.sameHome(home, $0) }
    }
}
