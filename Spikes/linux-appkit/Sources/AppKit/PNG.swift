import Foundation

/// A PNG writer with no dependency beyond Foundation: zlib's *stored* deflate blocks, which are
/// legal and trivial, so the spike needs no system library and the container needs no package.
public enum PNGWriter {

    public static func data(from bitmap: Bitmap) -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity(bitmap.height * (bitmap.width * 4 + 1))
        for row in 0..<bitmap.height {
            raw.append(0) // filter: none
            let start = row * bitmap.width * 4
            raw.append(contentsOf: bitmap.pixels[start..<(start + bitmap.width * 4)])
        }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.append(be32(UInt32(bitmap.width)))
        header.append(be32(UInt32(bitmap.height)))
        header.append(contentsOf: [8, 6, 0, 0, 0]) // 8-bit RGBA
        png.append(chunk("IHDR", header))
        png.append(chunk("IDAT", zlibStored(raw)))
        png.append(chunk("IEND", Data()))
        return png
    }

    public static func write(_ bitmap: Bitmap, to url: URL) throws {
        try data(from: bitmap).write(to: url)
    }

    // MARK: - Containers

    private static func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var body = Data(type.utf8)
        body.append(payload)
        var chunk = be32(UInt32(payload.count))
        chunk.append(body)
        chunk.append(be32(crc32(body)))
        return chunk
    }

    private static func zlibStored(_ raw: [UInt8]) -> Data {
        var out = Data([0x78, 0x01])
        var offset = 0
        while offset < raw.count {
            let length = min(65_535, raw.count - offset)
            let final: UInt8 = offset + length >= raw.count ? 1 : 0
            out.append(final)
            out.append(UInt8(length & 0xFF)); out.append(UInt8(length >> 8 & 0xFF))
            let complement = UInt16(length) ^ 0xFFFF
            out.append(UInt8(complement & 0xFF)); out.append(UInt8(complement >> 8 & 0xFF))
            out.append(contentsOf: raw[offset..<(offset + length)])
            offset += length
        }
        out.append(be32(adler32(raw)))
        return out
    }

    // MARK: - Checksums

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data { value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
        return value ^ 0xFFFF_FFFF
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }
}
