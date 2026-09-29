import Foundation

/// Wraps raw Opus packets into Ogg pages (RFC 3533 / RFC 7845).
///
/// The muxer is deliberately unbuffered: every `page(packets:durations48k:)` call returns bytes
/// immediately so they can be sent as a WebSocket binary message without added latency.
///
/// Packet-splitting behavior: a packet is never split across pages. When the packets passed to a
/// single call need more than 255 lacing values, they are distributed greedily over as many pages as
/// required (returned concatenated). A single packet must itself fit in one page, so its length must
/// be at most `maxPacketSize` (65,024 bytes); larger packets are rejected with a precondition. Real
/// Opus packets are at most a few KB, so this limit is never reached in practice.
struct OggOpusMuxer: Sendable {
    /// Largest packet that fits in one page: 255 lacing values, the last of which must be < 255.
    static let maxPacketSize = 255 * 255 - 1

    private static let maxSegmentsPerPage = 255
    private static let headerLength = 27

    private let serialNumber: UInt32
    private let channelCount: UInt8
    private let inputSampleRate: UInt32
    private let preSkip: UInt16
    private let vendor: String

    private var nextSequenceNumber: UInt32 = 0
    private var granulePosition: Int64 = 0

    init(
        serialNumber: UInt32,
        channelCount: UInt8 = 1,
        inputSampleRate: UInt32 = 16_000,
        preSkip: UInt16 = 312,
        vendor: String = "Larmindon"
    ) {
        self.serialNumber = serialNumber
        self.channelCount = channelCount
        self.inputSampleRate = inputSampleRate
        self.preSkip = preSkip
        self.vendor = vendor
    }

    /// The two header pages (OpusHead page, then OpusTags page), concatenated.
    /// Must be called once, before any audio page.
    mutating func headerPages() -> Data {
        var head = Data("OpusHead".utf8)
        head.append(1)  // version
        head.append(channelCount)
        head.appendLittleEndian(preSkip)
        head.appendLittleEndian(inputSampleRate)
        head.appendLittleEndian(Int16(0))  // output gain
        head.append(0)  // channel mapping family

        var tags = Data("OpusTags".utf8)
        let vendorBytes = Data(vendor.utf8)
        tags.appendLittleEndian(UInt32(vendorBytes.count))
        tags.append(vendorBytes)
        tags.appendLittleEndian(UInt32(0))  // user comment list length

        var output = makePage(packets: [head], granulePosition: 0, isBeginningOfStream: true)
        output.append(makePage(packets: [tags], granulePosition: 0, isBeginningOfStream: false))
        return output
    }

    /// One Ogg page containing the given Opus packets, in order.
    /// `durations48k[i]` is the duration of `packets[i]` in 48 kHz samples (960 for a 20 ms packet).
    /// If the packets need more than 255 lacing values they are split across several pages,
    /// returned concatenated.
    mutating func page(packets: [Data], durations48k: [Int]) -> Data {
        precondition(!packets.isEmpty, "At least one packet is required")
        precondition(packets.count == durations48k.count, "One duration is required per packet")

        var output = Data()
        var pending: [Data] = []
        var pendingSegments = 0

        for (packet, duration) in zip(packets, durations48k) {
            precondition(packet.count <= Self.maxPacketSize, "Packet too large for a single Ogg page")
            precondition(duration >= 0, "Packet duration must not be negative")
            let segments = packet.count / 255 + 1
            if pendingSegments + segments > Self.maxSegmentsPerPage {
                output.append(makePage(packets: pending, granulePosition: granulePosition, isBeginningOfStream: false))
                pending.removeAll(keepingCapacity: true)
                pendingSegments = 0
            }
            pending.append(packet)
            pendingSegments += segments
            granulePosition += Int64(duration)
        }
        output.append(makePage(packets: pending, granulePosition: granulePosition, isBeginningOfStream: false))
        return output
    }

    private mutating func makePage(
        packets: [Data],
        granulePosition: Int64,
        isBeginningOfStream: Bool
    ) -> Data {
        var lacing: [UInt8] = []
        for packet in packets {
            lacing.append(contentsOf: [UInt8](repeating: 255, count: packet.count / 255))
            lacing.append(UInt8(packet.count % 255))
        }

        var page = Data(capacity: Self.headerLength + lacing.count + packets.reduce(0) { $0 + $1.count })
        page.append(contentsOf: Array("OggS".utf8))
        page.append(0)  // stream structure version
        page.append(isBeginningOfStream ? 0x02 : 0x00)
        page.appendLittleEndian(granulePosition)
        page.appendLittleEndian(serialNumber)
        page.appendLittleEndian(nextSequenceNumber)
        page.appendLittleEndian(UInt32(0))  // CRC placeholder
        page.append(UInt8(lacing.count))
        page.append(contentsOf: lacing)
        for packet in packets {
            page.append(packet)
        }

        let crc = Self.crc32(page)
        let crcOffset = 22
        for index in 0..<4 {
            page[crcOffset + index] = UInt8(truncatingIfNeeded: crc >> (8 * UInt32(index)))
        }

        nextSequenceNumber &+= 1
        return page
    }

    // MARK: - CRC

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index) << 24
        for _ in 0..<8 {
            value = (value & 0x8000_0000) != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1
        }
        return value
    }

    /// Ogg CRC-32: polynomial 0x04C11DB7, initial value 0, MSB-first, no final XOR.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc = (crc << 8) ^ crcTable[Int((crc >> 24) ^ UInt32(byte))]
        }
        return crc
    }
}

extension Data {
    fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
