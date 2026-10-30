import Foundation

/// Reads the text of a Zstandard file a piece at a time (RFC 8878), holding no more of it than a frame's window and one
/// block: a Codex rollout that decodes to over a gigabyte takes about 2.5 MB. Frames follow one another and skippable
/// frames are passed over; a frame's stated content size is checked, its checksum is not.
final class ZstandardReader {
    /// The largest window a frame may ask for: the reference decoder's default limit.
    static let largestWindow = 1 << 27

    #if canImport(Darwin)
    private let descriptor: Int32
    #else
    private let handle: FileHandle
    #endif
    private static let inputCapacity = 256 << 10
    /// Compressed bytes read from the file and not decoded yet; the 16 bytes past its capacity are padding that bit
    /// readers may load without using.
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity + 16)
    private var inputStart = 0, inputEnd = 0, fileEnded = false
    /// Decoded text: the frame's window of earlier text, which matches copy from, then text not handed out yet.
    private var output = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
    private var outputCapacity = 0, outputStart = 0, outputEnd = 0
    private var frame: Frame?
    private let blocks = ZstandardBlocks()
    /// How much text was handed out.
    private(set) var position = 0

    private struct Frame {
        let header: ZstandardFrameHeader
        var decoded = 0
        var ended = false
        var blockLimit: Int { min(header.window, ZstandardBlocks.largestSize) }
    }

    init(url: URL) throws {
        #if canImport(Darwin)
        descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            input.deallocate(); output.deallocate()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        #else
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            input.deallocate(); output.deallocate()
            throw error
        }
        #endif
        input.initialize(repeating: 0, count: Self.inputCapacity + 16)
    }

    deinit {
        #if canImport(Darwin)
        close(descriptor)
        #else
        try? handle.close()
        #endif
        input.deallocate()
        output.deallocate()
    }

    /// The size of the text the first frame of a file holds, as its header states it; nil when it does not state it, or
    /// when the file starts with a skippable frame.
    static func contentSize(of url: URL) throws -> Int? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = [UInt8](try handle.read(upToCount: ZstandardFrameHeader.largestLength) ?? Data())
        return try bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, buffer.count >= 4 else { throw ZstandardError.notZstandard }
            if ZstandardFrameHeader.isSkippable(base) { return nil }
            guard let header = try ZstandardFrameHeader(base, available: buffer.count) else { throw ZstandardError.corrupt }
            return header.contentSize
        }
    }

    /// Up to `count` bytes of text; fewer only at its end, and none after it.
    func read(upToCount count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            if outputStart == outputEnd { guard try decodeBlock() else { break } }
            let length = min(count - data.count, outputEnd - outputStart)
            data.append(output + outputStart, count: length)
            outputStart += length
            position += length
        }
        return data
    }

    /// Passes over up to `count` bytes of text; returns how many, fewer only at its end.
    @discardableResult
    func skip(_ count: Int) throws -> Int {
        var left = count
        while left > 0 {
            if outputStart == outputEnd { guard try decodeBlock() else { break } }
            let length = min(left, outputEnd - outputStart)
            outputStart += length
            position += length
            left -= length
        }
        return count - left
    }

    /// Decodes the next block that holds text, starting frames and passing over frame ends on the way; false at the end
    /// of the file. Called only once every decoded byte was handed out.
    private func decodeBlock() throws -> Bool {
        while true {
            guard var frame else {
                guard try fill(4) else {
                    guard inputStart == inputEnd else { throw ZstandardError.corrupt }
                    return false
                }
                try startFrame()
                continue
            }
            if frame.ended {
                if let size = frame.header.contentSize, size != frame.decoded { throw ZstandardError.corrupt }
                if frame.header.checksum {
                    guard try fill(4) else { throw ZstandardError.corrupt }
                    inputStart += 4
                }
                self.frame = nil
                continue
            }
            guard try fill(3) else { throw ZstandardError.corrupt }
            let header = Int(input[inputStart]) | Int(input[inputStart + 1]) << 8 | Int(input[inputStart + 2]) << 16
            let type = (header >> 1) & 3, size = header >> 3
            guard type != 3, size <= frame.blockLimit else { throw ZstandardError.corrupt }
            makeRoom(for: frame)
            let start = outputEnd
            switch type {
            case 0:
                guard try fill(3 + size) else { throw ZstandardError.corrupt }
                (output + outputEnd).update(from: input + inputStart + 3, count: size)
                outputEnd += size
                inputStart += 3 + size
            case 1:
                guard try fill(4) else { throw ZstandardError.corrupt }
                (output + outputEnd).update(repeating: input[inputStart + 3], count: size)
                outputEnd += size
                inputStart += 4
            default:
                guard try fill(3 + size) else { throw ZstandardError.corrupt }
                outputEnd = try blocks.decode(input + inputStart + 3, count: size, into: output, at: outputEnd, limit: frame.blockLimit)
                inputStart += 3 + size
            }
            frame.decoded += outputEnd - start
            frame.ended = header & 1 == 1
            if let size = frame.header.contentSize, frame.decoded > size { throw ZstandardError.corrupt }
            self.frame = frame
            if outputEnd > start { return true }
        }
    }

    /// Reads the header of the frame that starts the input, or passes over a skippable frame.
    private func startFrame() throws {
        if ZstandardFrameHeader.isSkippable(input + inputStart) {
            guard try fill(8) else { throw ZstandardError.corrupt }
            var left = (0..<4).reduce(0) { $0 | Int(input[inputStart + 4 + $1]) << (8 * $1) }
            inputStart += 8
            while left > 0 {
                guard try fill(1) else { throw ZstandardError.corrupt }
                let length = min(left, inputEnd - inputStart)
                inputStart += length
                left -= length
            }
            return
        }
        guard try fill(ZstandardFrameHeader.largestLength) || inputEnd > inputStart,
              let header = try ZstandardFrameHeader(input + inputStart, available: inputEnd - inputStart) else {
            throw position == 0 ? ZstandardError.notZstandard : ZstandardError.corrupt
        }
        guard header.window <= Self.largestWindow else { throw ZstandardError.unsupported }
        inputStart += header.length
        let frame = Frame(header: header)
        // Matches stay within their frame, so a new frame needs no earlier text.
        let capacity = header.window + frame.blockLimit
        if capacity > outputCapacity {
            output.deallocate()
            output = .allocate(capacity: capacity + 16)
            outputCapacity = capacity
        }
        outputStart = 0; outputEnd = 0
        blocks.startFrame()
        self.frame = frame
    }

    /// Makes room for a block after the text, keeping the window of earlier text that its matches may copy from. The
    /// output holds only the current frame's text, so the window starts no earlier than the frame.
    private func makeRoom(for frame: Frame) {
        guard outputEnd + frame.blockLimit > outputCapacity else { return }
        let kept = min(frame.header.window, outputEnd)
        memmove(output, output + outputEnd - kept, kept)
        outputStart = kept; outputEnd = kept
    }

    /// Reads from the file until `count` compressed bytes wait in the input; false when the file ends first.
    private func fill(_ count: Int) throws -> Bool {
        if inputEnd - inputStart >= count { return true }
        if inputStart > 0 {
            memmove(input, input + inputStart, inputEnd - inputStart)
            inputEnd -= inputStart
            inputStart = 0
        }
        while inputEnd < count, !fileEnded {
            #if canImport(Darwin)
            let length = Darwin.read(descriptor, input + inputEnd, Self.inputCapacity - inputEnd)
            if length < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            #else
            let chunk = try handle.read(upToCount: Self.inputCapacity - inputEnd) ?? Data()
            chunk.copyBytes(to: input + inputEnd, count: chunk.count)
            let length = chunk.count
            #endif
            if length == 0 { fileEnded = true } else { inputEnd += length }
        }
        return inputEnd - inputStart >= count
    }
}

/// The header that starts a Zstandard frame (RFC 8878, 3.1.1.1).
struct ZstandardFrameHeader {
    static let largestLength = 18
    /// The header's own length.
    let length: Int
    /// How far back a match may reach.
    let window: Int
    let checksum: Bool
    let contentSize: Int?

    static func isSkippable(_ base: UnsafePointer<UInt8>) -> Bool {
        base[0] & 0xF0 == 0x50 && base[1] == 0x2A && base[2] == 0x4D && base[3] == 0x18
    }

    /// The header at `base`, nil when fewer than its length of `available` bytes hold it.
    init?(_ base: UnsafePointer<UInt8>, available: Int) throws {
        guard available >= 5 else { return nil }
        guard base[0] == 0x28, base[1] == 0xB5, base[2] == 0x2F, base[3] == 0xFD else { throw ZstandardError.notZstandard }
        let descriptor = Int(base[4]), single = descriptor & 0x20 != 0
        guard descriptor & 0x08 == 0 else { throw ZstandardError.corrupt }
        let dictionaryLength = [0, 1, 2, 4][descriptor & 3], sizeLength = [single ? 1 : 0, 2, 4, 8][descriptor >> 6]
        length = 5 + (single ? 0 : 1) + dictionaryLength + sizeLength
        guard available >= length else { return nil }
        var at = 5, window = 0
        if !single {
            let exponent = Int(base[at] >> 3), mantissa = Int(base[at] & 7)
            let base = 1 << (10 + exponent)
            window = base + (base >> 3) * mantissa
            at += 1
        }
        func number(_ count: Int) -> UInt64 { (0..<count).reduce(0) { $0 | UInt64(base[at + $1]) << (8 * $1) } }
        guard number(dictionaryLength) == 0 else { throw ZstandardError.unsupported }
        at += dictionaryLength
        if sizeLength > 0 {
            let size = number(sizeLength) + (sizeLength == 2 ? 256 : 0)
            guard size <= UInt64(Int.max) else { throw ZstandardError.unsupported }
            contentSize = Int(size)
        } else {
            contentSize = nil
        }
        self.window = single ? contentSize ?? 0 : window
        checksum = descriptor & 0x04 != 0
    }
}
