import Foundation
import Compression

struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
        let crc: UInt32
    }

    private let data: Data
    private let entries: [String: Entry]

    init(data: Data) throws {
        self.data = data
        self.entries = try ZipArchive.readEntries(from: data)
    }

    func data(for name: String) throws -> Data {
        guard let entry = entries[name] else { throw ZipError.missing(name) }
        let offset = entry.localOffset
        guard offset >= 0, offset + 30 <= data.count, data.uint32(at: offset) == 0x04034b50 else { throw ZipError.invalid }
        let nameLength = Int(data.uint16(at: offset + 26))
        let extraLength = Int(data.uint16(at: offset + 28))
        let start = offset + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count else { throw ZipError.invalid }
        let payload = data.subdata(in: start..<end)
        let decoded: Data
        switch entry.method {
        case 0: decoded = payload
        case 8: decoded = try inflate(payload, expectedSize: entry.uncompressedSize)
        default: throw ZipError.unsupportedCompression
        }
        guard decoded.count == entry.uncompressedSize, CRC32.checksum(decoded) == entry.crc else { throw ZipError.invalid }
        return decoded
    }

    var names: [String] { Array(entries.keys) }

    private func inflate(_ payload: Data, expectedSize: Int) throws -> Data {
        guard expectedSize <= 256 * 1024 * 1024 else { throw ZipError.invalid }
        if expectedSize == 0 { return Data() }
        let outputCapacity = expectedSize
        var output = Data(count: outputCapacity)
        let decoded = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { inputBytes in
                compression_decode_buffer(
                    outputBytes.bindMemory(to: UInt8.self).baseAddress!, outputCapacity,
                    inputBytes.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == expectedSize else { throw ZipError.decompressionFailed }
        output.count = decoded
        return output
    }

    private static func readEntries(from data: Data) throws -> [String: Entry] {
        let lowerBound = max(0, data.count - 65_557)
        var eocd = -1
        if data.count >= 22 {
            for offset in stride(from: data.count - 22, through: lowerBound, by: -1) where data.uint32(at: offset) == 0x06054b50 {
                eocd = offset
                break
            }
        }
        guard eocd >= 0 else { throw ZipError.invalid }
        let count = Int(data.uint16(at: eocd + 10))
        guard data.uint16(at: eocd + 4) == 0, data.uint16(at: eocd + 6) == 0, count < 65535 else { throw ZipError.invalid }
        let directorySize = Int(data.uint32(at: eocd + 12))
        let directoryOffset = Int(data.uint32(at: eocd + 16))
        guard directoryOffset + directorySize <= data.count else { throw ZipError.invalid }

        var result: [String: Entry] = [:]
        var cursor = directoryOffset
        var totalSize = 0
        for _ in 0..<count {
            guard cursor + 46 <= data.count, data.uint32(at: cursor) == 0x02014b50, data.uint16(at: cursor + 8) & 1 == 0 else { throw ZipError.invalid }
            let method = data.uint16(at: cursor + 10)
            let compressedSize = Int(data.uint32(at: cursor + 20))
            let uncompressedSize = Int(data.uint32(at: cursor + 24))
            let nameLength = Int(data.uint16(at: cursor + 28))
            let extraLength = Int(data.uint16(at: cursor + 30))
            let commentLength = Int(data.uint16(at: cursor + 32))
            let localOffset = Int(data.uint32(at: cursor + 42))
            totalSize += uncompressedSize
            guard totalSize <= 512 * 1024 * 1024, localOffset + 30 <= data.count else { throw ZipError.invalid }
            let nameStart = cursor + 46
            guard nameStart + nameLength + extraLength + commentLength <= data.count else { throw ZipError.invalid }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            guard result[name] == nil else { throw ZipError.invalid }
            result[name] = Entry(name: name, method: method, compressedSize: compressedSize, uncompressedSize: uncompressedSize, localOffset: localOffset, crc: data.uint32(at: cursor + 16))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return result
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
}

enum ZipError: LocalizedError {
    case invalid, missing(String), unsupportedCompression, decompressionFailed
    var errorDescription: String? {
        switch self {
        case .invalid: return "Архив повреждён или имеет неподдерживаемую структуру"
        case .missing(let name): return "В архиве отсутствует файл \(name)"
        case .unsupportedCompression: return "Метод сжатия архива не поддерживается"
        case .decompressionFailed: return "Не удалось распаковать файл из архива"
        }
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }
}
