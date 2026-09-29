import Foundation
import XCTest
@testable import LarmindonKit

final class OggOpusMuxerTests: XCTestCase {
    private struct ParsedPage {
        var flags: UInt8
        var granule: Int64
        var serial: UInt32
        var sequence: UInt32
        var storedCRC: UInt32
        var lacing: [UInt8]
        var body: [UInt8]
        var raw: [UInt8]
    }

    private func littleEndian<T: FixedWidthInteger>(_ bytes: ArraySlice<UInt8>, as _: T.Type) -> T {
        bytes.enumerated().reduce(T(0)) { $0 | (T($1.element) << (8 * $1.offset)) }
    }

    private func parsePages(_ data: Data) throws -> [ParsedPage] {
        let bytes = [UInt8](data)
        var pages: [ParsedPage] = []
        var offset = 0
        while offset < bytes.count {
            XCTAssertEqual(Array(bytes[offset..<offset + 4]), Array("OggS".utf8))
            XCTAssertEqual(bytes[offset + 4], 0)
            let segmentCount = Int(bytes[offset + 26])
            let lacing = Array(bytes[offset + 27..<offset + 27 + segmentCount])
            let bodyStart = offset + 27 + segmentCount
            let bodyLength = lacing.reduce(0) { $0 + Int($1) }
            let end = bodyStart + bodyLength
            XCTAssertLessThanOrEqual(end, bytes.count)
            guard end <= bytes.count else { throw XCTSkip("Truncated page") }
            pages.append(
                ParsedPage(
                    flags: bytes[offset + 5],
                    granule: Int64(bitPattern: littleEndian(bytes[offset + 6..<offset + 14], as: UInt64.self)),
                    serial: littleEndian(bytes[offset + 14..<offset + 18], as: UInt32.self),
                    sequence: littleEndian(bytes[offset + 18..<offset + 22], as: UInt32.self),
                    storedCRC: littleEndian(bytes[offset + 22..<offset + 26], as: UInt32.self),
                    lacing: lacing,
                    body: Array(bytes[bodyStart..<end]),
                    raw: Array(bytes[offset..<end])
                )
            )
            offset = end
        }
        return pages
    }

    private func recomputedCRC(_ page: ParsedPage) -> UInt32 {
        var raw = page.raw
        for index in 22..<26 { raw[index] = 0 }
        return OggOpusMuxer.crc32(Data(raw))
    }

    private func packet(length: Int, fill: UInt8 = 0xAB) -> Data {
        Data(repeating: fill, count: length)
    }

    func testCRCCheckValue() {
        XCTAssertEqual(OggOpusMuxer.crc32(Data("123456789".utf8)), 0x89A1_897F)
    }

    func testOpusHeadPageBytes() throws {
        var muxer = OggOpusMuxer(serialNumber: 0x0102_0304)
        let pages = try parsePages(muxer.headerPages())
        XCTAssertEqual(pages.count, 2)

        let head = pages[0]
        XCTAssertEqual(head.flags, 0x02)
        XCTAssertEqual(head.granule, 0)
        XCTAssertEqual(head.serial, 0x0102_0304)
        XCTAssertEqual(head.sequence, 0)
        XCTAssertEqual(head.lacing, [19])
        XCTAssertEqual(
            head.body,
            Array("OpusHead".utf8) + [
                1,  // version
                1,  // channels
                0x38, 0x01,  // pre-skip 312
                0x80, 0x3E, 0x00, 0x00,  // 16000 Hz
                0x00, 0x00,  // output gain
                0,  // mapping family
            ]
        )
        XCTAssertEqual(head.storedCRC, recomputedCRC(head))
        // Fixed header prefix, byte for byte.
        XCTAssertEqual(
            Array(head.raw[0..<22]),
            Array("OggS".utf8) + [0, 0x02] + [UInt8](repeating: 0, count: 8) + [4, 3, 2, 1] + [0, 0, 0, 0]
        )
        XCTAssertEqual(head.raw[26], 1)
    }

    func testOpusTagsPageBytes() throws {
        var muxer = OggOpusMuxer(serialNumber: 7, vendor: "Larmindon")
        let pages = try parsePages(muxer.headerPages())
        let tags = pages[1]
        XCTAssertEqual(tags.flags, 0)
        XCTAssertEqual(tags.granule, 0)
        XCTAssertEqual(tags.sequence, 1)
        XCTAssertEqual(tags.serial, 7)
        XCTAssertEqual(tags.lacing, [8 + 4 + 9 + 4])
        XCTAssertEqual(
            tags.body,
            Array("OpusTags".utf8) + [9, 0, 0, 0] + Array("Larmindon".utf8) + [0, 0, 0, 0]
        )
        XCTAssertEqual(tags.storedCRC, recomputedCRC(tags))
    }

    func testSequenceNumbersAndBeginningOfStreamFlag() throws {
        var muxer = OggOpusMuxer(serialNumber: 42)
        var stream = muxer.headerPages()
        for _ in 0..<3 {
            stream.append(muxer.page(packets: [Data([0xF8, 0xFF, 0xFE])], durations48k: [960]))
        }
        let pages = try parsePages(stream)
        XCTAssertEqual(pages.map(\.sequence), [0, 1, 2, 3, 4])
        XCTAssertEqual(pages.map(\.flags), [0x02, 0, 0, 0, 0])
        XCTAssertEqual(Set(pages.map(\.serial)), [42])
        for page in pages {
            XCTAssertEqual(page.storedCRC, recomputedCRC(page))
        }
    }

    func testGranulePositionAccumulatesAcrossCalls() throws {
        var muxer = OggOpusMuxer(serialNumber: 1)
        _ = muxer.headerPages()
        var stream = Data()
        stream.append(muxer.page(packets: [packet(length: 3)], durations48k: [960]))
        stream.append(muxer.page(packets: [packet(length: 3), packet(length: 3)], durations48k: [960, 1920]))
        stream.append(muxer.page(packets: [packet(length: 3)], durations48k: [480]))
        let pages = try parsePages(stream)
        XCTAssertEqual(pages.map(\.granule), [960, 3840, 4320])
    }

    func testLacingTables() throws {
        var muxer = OggOpusMuxer(serialNumber: 1)
        _ = muxer.headerPages()
        let lengths = [0, 100, 255, 256, 510]
        let packets = lengths.map { packet(length: $0) }
        let pages = try parsePages(muxer.page(packets: packets, durations48k: [960, 960, 960, 960, 960]))
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].lacing, [0, 100, 255, 0, 255, 1, 255, 255, 0])
        XCTAssertEqual(pages[0].body.count, lengths.reduce(0, +))
        XCTAssertEqual(pages[0].storedCRC, recomputedCRC(pages[0]))
    }

    func testManyPacketsSplitAcrossPagesWithoutLosingData() throws {
        var muxer = OggOpusMuxer(serialNumber: 9)
        _ = muxer.headerPages()
        // 600 packets of ~1 segment each need at least three pages; mix in some 2-segment packets.
        let packets = (0..<600).map { index in
            packet(length: index % 5 == 0 ? 300 : 50, fill: UInt8(index % 251))
        }
        let pages = try parsePages(muxer.page(packets: packets, durations48k: Array(repeating: 960, count: 600)))
        XCTAssertGreaterThan(pages.count, 2)
        XCTAssertEqual(pages.map(\.sequence), Array(2..<UInt32(2 + pages.count)))
        XCTAssertTrue(pages.allSatisfy { $0.lacing.count <= 255 && $0.flags == 0 })
        XCTAssertTrue(pages.allSatisfy { $0.storedCRC == recomputedCRC($0) })
        XCTAssertEqual(pages.last?.granule, 600 * 960)

        let expectedBody = packets.reduce(into: [UInt8]()) { $0.append(contentsOf: $1) }
        XCTAssertEqual(pages.flatMap(\.body), expectedBody)

        // Every page ends on a packet boundary (final lacing value < 255) and granules never decrease.
        XCTAssertTrue(pages.allSatisfy { ($0.lacing.last ?? 0) < 255 })
        XCTAssertEqual(pages.map(\.granule), pages.map(\.granule).sorted())
        let totalPackets = pages.reduce(0) { $0 + $1.lacing.filter { $0 < 255 }.count }
        XCTAssertEqual(totalPackets, 600)
    }

    func testLargestPacketFitsInOnePage() throws {
        var muxer = OggOpusMuxer(serialNumber: 1)
        _ = muxer.headerPages()
        let big = packet(length: OggOpusMuxer.maxPacketSize)
        let pages = try parsePages(muxer.page(packets: [big], durations48k: [960]))
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].lacing.count, 255)
        XCTAssertEqual(pages[0].body.count, big.count)
    }
}
