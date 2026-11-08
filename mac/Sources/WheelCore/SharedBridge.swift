import CWheelBridge
import Darwin
import Foundation

/// The shared memory file, mapped into this process.
public final class SharedBridge: @unchecked Sendable {
    public enum Failure: Error { case open(String), map(String), incompatible }

    private let memory: UnsafeMutablePointer<wb_bridge>

    public static var defaultURL: URL { Paths.supportDirectory.appendingPathComponent("bridge.bin") }

    /// Maps the file. The helper passes `owner` to create and stamp it, and
    /// anyone else attaches to what the helper made.
    public init(url: URL = SharedBridge.defaultURL, owner: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, owner ? O_RDWR | O_CREAT : O_RDWR, 0o600)
        guard descriptor >= 0 else { throw Failure.open(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        // Never truncated while mapped, because a game may already be attached.
        if owner, ftruncate(descriptor, off_t(WB_FILE_SIZE)) != 0 {
            throw Failure.open(String(cString: strerror(errno)))
        }
        let mapped = mmap(nil, Int(WB_FILE_SIZE), PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        guard let mapped, mapped != MAP_FAILED else { throw Failure.map(String(cString: strerror(errno))) }
        memory = mapped.bindMemory(to: wb_bridge.self, capacity: 1)
        if owner {
            memory.pointee.version = WB_VERSION
            memory.pointee.size = UInt32(MemoryLayout<wb_bridge>.size)
            memory.pointee.helper_pid = UInt32(getpid())
            memory.pointee.magic = WB_MAGIC
        } else if memory.pointee.magic != WB_MAGIC || memory.pointee.version != WB_VERSION {
            munmap(mapped, Int(WB_FILE_SIZE))
            throw Failure.incompatible
        }
    }

    deinit { munmap(memory, Int(WB_FILE_SIZE)) }

    public func publish(input: wb_input) {
        var value = input
        wb_write(&memory.pointee.input, &value, MemoryLayout<wb_input>.size)
    }

    public func readInput() -> wb_input? { read(&memory.pointee.input) }

    public func publish(status: wb_status) {
        var value = status
        wb_write(&memory.pointee.status, &value, MemoryLayout<wb_status>.size)
    }

    public func readStatus() -> wb_status? { read(&memory.pointee.status) }

    public func publish(settings: wb_settings) {
        var value = settings
        wb_write(&memory.pointee.settings, &value, MemoryLayout<wb_settings>.size)
    }

    public func readSettings() -> wb_settings? { read(&memory.pointee.settings) }

    public func readGame() -> wb_game? { read(&memory.pointee.game) }

    /// Clears anything a game left behind, so an old session cannot drive the motor.
    public func resetGame() {
        var empty = wb_game()
        wb_write(&memory.pointee.game, &empty, MemoryLayout<wb_game>.size)
    }

    private func read<T>(_ block: UnsafeMutablePointer<T>) -> T? {
        let copy = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { copy.deallocate() }
        return wb_read(block, copy, MemoryLayout<T>.size) != 0 ? copy.pointee : nil
    }
}

/// Reads and writes the fixed-size C strings in the shared blocks.
public enum BridgeText {
    public static func read<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    public static func write<T>(_ text: String, to tuple: inout T) {
        withUnsafeMutableBytes(of: &tuple) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in text.utf8.prefix(bytes.count - 1).enumerated() { bytes[index] = byte }
        }
    }
}

public enum Paths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WheelBridge", isDirectory: true)
    }
}
