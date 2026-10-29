import Foundation

extension FileHandle {
    /// Everything up to end of file, or what could be read before an error.
    ///
    /// `readDataToEndOfFile()` and `availableData` raise an Objective-C
    /// exception when the read fails, which Swift cannot catch and which
    /// aborts the app. Use these for reading child process pipes.
    func readToEndSafely() -> Data {
        (try? readToEnd()) ?? Data()
    }

    /// The bytes available now, or empty at end of file or on error. Like
    /// `availableData`, this is one read(2): it returns what is there
    /// instead of waiting for a full buffer.
    func availableDataSafely() -> Data {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 { return Data(buffer[..<count]) }
            if count < 0 && errno == EINTR { continue }
            return Data()
        }
    }
}
