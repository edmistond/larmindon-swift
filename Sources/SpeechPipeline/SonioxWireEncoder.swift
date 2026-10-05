import AVFAudio
import Foundation

/// Turns captured audio into the bytes sent to Soniox.
///
/// Each WebSocket connection is its own audio stream as far as Soniox is concerned, so a
/// container format has to start over for every connection: call `startStream()` once per
/// connection, send its bytes first, then send whatever `encode` returns.
protocol SonioxWireEncoder: AnyObject, Sendable {
    /// What goes in the Soniox configuration's `audio_format`.
    var audioFormat: SonioxAudioFormat { get }
    /// The encoding actually in use, which can differ from the one requested if the
    /// requested codec was unavailable.
    var encoding: SonioxAudioEncoding { get }
    var diagnosticFields: [String: String] { get }

    /// Resets encoder state for a new connection and returns bytes to send before any audio
    /// (container headers). Empty for raw PCM.
    func startStream() -> Data

    /// Bytes for one captured buffer. `nil` means conversion failed; empty `Data` means the
    /// encoder is holding the audio until it has a full packet.
    func encode(_ buffer: AVAudioPCMBuffer) -> Data?

    /// Audio a decoder gets from everything `encode` has returned since `startStream()`,
    /// after trimming any codec lookahead. Audio fed minus this is what the encoder is
    /// holding, which delays every caption by that much.
    var emittedDuration: Duration { get }
}

enum SonioxWireEncoders {
    /// Falls back to PCM if the platform's encoder can't be created, so a missing codec
    /// costs bandwidth rather than captions.
    static func make(
        for encoding: SonioxAudioEncoding,
        opusBitRate: SonioxOpusBitRate = SonioxOpusBitRate.defaultValue,
        flacSampleRate: SonioxFLACSampleRate = SonioxFLACSampleRate.defaultValue
    ) -> any SonioxWireEncoder {
        switch encoding {
        case .pcm:
            return SonioxPCMConverter()
        case .opus:
            return SonioxOpusEncoder(bitRate: opusBitRate) ?? SonioxPCMConverter()
        case .flac:
            return SonioxFLACEncoder(sampleRate: flacSampleRate) ?? SonioxPCMConverter()
        }
    }
}

/// Opus at a chosen bitrate, wrapped in Ogg pages that are sent as soon as each packet exists.
///
/// Apple's encoder takes 20 ms (320-frame) packets at 16 kHz and holds any remainder until the
/// next buffer, so at most one capture buffer of audio waits in the encoder. Measured on
/// synthesized speech at 24 kbps: about 2.9 KB/s of Opus plus a 28-byte Ogg page header per
/// 20 ms packet, so about 4.3 KB/s on the wire versus 32 KB/s for PCM. One packet per page
/// keeps latency at a single packet; batching would save header bytes at the cost of delay.
///
/// 24 kbps hurt accuracy on deaf-accented speech in hardware testing, hence the setting.
/// Variable bitrate is requested so consonant onsets can borrow bits from steady vowels and
/// silence; whether Apple's encoder honors it is reported in `diagnosticFields`.
final class SonioxOpusEncoder: SonioxWireEncoder, @unchecked Sendable {
    private static let sampleRate = 16_000.0
    private static let framesPerPacket: UInt32 = 320
    /// Ogg Opus measures time in 48 kHz samples whatever the coded rate.
    private static let granuleScale = Int(48_000 / sampleRate)

    let audioFormat = SonioxAudioFormat.auto
    let encoding = SonioxAudioEncoding.opus

    private let resampler = SonioxPCMConverter()
    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    private let lock = NSLock()
    private var converter: AVAudioConverter
    private var muxer: OggOpusMuxer
    private var packetsEmitted = 0
    let bitRate: SonioxOpusBitRate

    init?(bitRate: SonioxOpusBitRate = SonioxOpusBitRate.defaultValue) {
        self.bitRate = bitRate
        var description = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: Self.framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard
            let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let opusFormat = AVAudioFormat(streamDescription: &description),
            let converter = Self.makeConverter(from: pcmFormat, to: opusFormat, bitRate: bitRate)
        else {
            return nil
        }
        self.pcmFormat = pcmFormat
        self.opusFormat = opusFormat
        self.converter = converter
        self.muxer = Self.makeMuxer(for: converter)
    }

    var diagnosticFields: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        // What the converter reports back, not what was asked for, so a bundle shows
        // whether the encoder accepted the rate and strategy.
        return [
            "audio_format": audioFormat.rawValue,
            "codec": "opus",
            "container": "ogg",
            "bit_rate_requested": String(bitRate.rawValue),
            "bit_rate": String(converter.bitRate),
            "bit_rate_strategy": converter.bitRateStrategy ?? "unset",
            "sample_rate": String(Int(Self.sampleRate)),
            "channels": "1",
            "packet_frames": String(Self.framesPerPacket),
            // Lookahead a decoder trims from the start: delay added to every caption.
            "pre_skip_frames": String(converter.primeInfo.leadingFrames),
        ]
    }

    /// Packets times 20 ms, less the lookahead a decoder trims. Measured on Apple's encoder:
    /// a packet is released as soon as 320 frames are in, so with the 104-frame lookahead
    /// (6.5 ms) it holds 6.5–26.5 ms of audio.
    var emittedDuration: Duration {
        lock.lock()
        defer { lock.unlock() }
        let frames = packetsEmitted * Int(Self.framesPerPacket) - Int(converter.primeInfo.leadingFrames)
        return .seconds(Double(max(0, frames)) / Self.sampleRate)
    }

    func startStream() -> Data {
        lock.lock()
        defer { lock.unlock() }
        packetsEmitted = 0
        // A fresh converter drops any partial packet from the previous connection, and a
        // fresh muxer restarts page numbering and granule positions under a new serial.
        if let fresh = Self.makeConverter(from: pcmFormat, to: opusFormat, bitRate: bitRate) {
            converter = fresh
        } else {
            converter.reset()
        }
        muxer = Self.makeMuxer(for: converter)
        return muxer.headerPages()
    }

    func encode(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let pcm = resampler.convertToBuffer(buffer) else { return nil }

        lock.lock()
        defer { lock.unlock() }

        // Generous: a maximum-size capture buffer (2048 frames at 48 kHz) is about three
        // packets.
        let output = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 16,
            maximumPacketSize: max(converter.maximumOutputPacketSize, 1)
        )
        let inputProvider = SonioxOpusInputProvider(buffer: pcm)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputProvider.nextBuffer(inputStatus: inputStatus)
        }
        guard status != .error else { return nil }
        guard output.packetCount > 0, let descriptions = output.packetDescriptions else {
            return Data()
        }

        packetsEmitted += Int(output.packetCount)
        var packets: [Data] = []
        packets.reserveCapacity(Int(output.packetCount))
        for index in 0..<Int(output.packetCount) {
            let packet = descriptions[index]
            packets.append(
                Data(
                    bytes: output.data.advanced(by: Int(packet.mStartOffset)),
                    count: Int(packet.mDataByteSize)
                )
            )
        }
        let duration = Int(Self.framesPerPacket) * Self.granuleScale
        return muxer.page(
            packets: packets,
            durations48k: Array(repeating: duration, count: packets.count)
        )
    }

    private static func makeConverter(
        from pcmFormat: AVAudioFormat,
        to opusFormat: AVAudioFormat,
        bitRate: SonioxOpusBitRate
    ) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: pcmFormat, to: opusFormat) else {
            return nil
        }
        converter.bitRate = bitRate.rawValue
        converter.bitRateStrategy = AVAudioBitRateStrategy_Variable
        return converter
    }

    private static func makeMuxer(for converter: AVAudioConverter) -> OggOpusMuxer {
        // The encoder's lookahead, which a decoder trims from the start. Apple reports it in
        // coded frames; Ogg Opus wants 48 kHz samples.
        let leadingFrames = Int(converter.primeInfo.leadingFrames) * granuleScale
        return OggOpusMuxer(
            serialNumber: UInt32.random(in: .min ... .max),
            channelCount: 1,
            inputSampleRate: UInt32(sampleRate),
            preSkip: UInt16(clamping: leadingFrames)
        )
    }
}

/// Lossless FLAC as a native FLAC stream: the `fLaC` marker and a STREAMINFO block once per
/// connection, then each encoded frame as soon as it exists.
///
/// Every sample Soniox decodes is identical to what PCM would have sent at the same rate,
/// so any difference in recognition comes from the sample rate or from the transport, never
/// the codec. Apple's encoder at 20 ms blocks compressed synthesized speech to 0.60 of PCM
/// at 16 kHz and 0.57 at 24 kHz, slightly better than libFLAC `-8` at the same block size;
/// larger blocks saved under 2% more while adding latency. Real microphone audio with room
/// noise compresses less, which `audio_send_window` reports.
///
/// The stream declares an unknown length and no MD5, which FLAC allows for streams and
/// libFLAC decodes as is. Apple's encoder releases a block only once the next one has
/// filled, so 20–40 ms of audio waits in it; 10 ms blocks would halve that for slightly
/// worse compression. A stop discards what it still holds, as with Opus.
final class SonioxFLACEncoder: SonioxWireEncoder, @unchecked Sendable {
    /// 20 ms, matching Opus's packet length so the two arms add the same encoder delay.
    private static let blockDuration = 0.020
    private static let bitsPerSample: UInt8 = 16

    let audioFormat = SonioxAudioFormat.auto
    let encoding = SonioxAudioEncoding.flac
    let sampleRate: SonioxFLACSampleRate

    private let resampler: SonioxPCMConverter
    private let pcmFormat: AVAudioFormat
    private let flacFormat: AVAudioFormat
    private let framesPerBlock: UInt32
    private let lock = NSLock()
    private var converter: AVAudioConverter
    private var blocksEmitted = 0

    init?(sampleRate: SonioxFLACSampleRate = SonioxFLACSampleRate.defaultValue) {
        self.sampleRate = sampleRate
        let rate = Double(sampleRate.rawValue)
        let framesPerBlock = UInt32(rate * Self.blockDuration)
        var description = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatFLAC,
            mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerBlock,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard
            let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: rate,
                channels: 1,
                interleaved: false
            ),
            let flacFormat = AVAudioFormat(streamDescription: &description),
            let converter = AVAudioConverter(from: pcmFormat, to: flacFormat)
        else {
            return nil
        }
        self.resampler = SonioxPCMConverter(sampleRate: rate)
        self.pcmFormat = pcmFormat
        self.flacFormat = flacFormat
        self.framesPerBlock = framesPerBlock
        self.converter = converter
    }

    var diagnosticFields: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "audio_format": audioFormat.rawValue,
            "codec": "flac",
            "container": "native",
            "sample_rate": String(sampleRate.rawValue),
            "channels": "1",
            "bits_per_sample": String(Self.bitsPerSample),
            // What the converter settled on, not what was asked for.
            "block_frames": String(converter.outputFormat.streamDescription.pointee.mFramesPerPacket),
        ]
    }

    /// FLAC has no lookahead, so this is whole blocks.
    var emittedDuration: Duration {
        lock.lock()
        defer { lock.unlock() }
        return .seconds(Double(blocksEmitted * Int(framesPerBlock)) / Double(sampleRate.rawValue))
    }

    func startStream() -> Data {
        lock.lock()
        defer { lock.unlock() }
        blocksEmitted = 0
        // A fresh converter drops any partial block from the previous connection and
        // restarts frame numbering, which a decoder expects to begin at zero.
        if let fresh = AVAudioConverter(from: pcmFormat, to: flacFormat) {
            converter = fresh
        } else {
            converter.reset()
        }
        return Self.streamHeader(
            sampleRate: UInt32(sampleRate.rawValue),
            channelCount: 1,
            bitsPerSample: Self.bitsPerSample,
            blockSize: UInt16(framesPerBlock)
        )
    }

    func encode(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let pcm = resampler.convertToBuffer(buffer) else { return nil }

        lock.lock()
        defer { lock.unlock() }

        // A maximum-size capture buffer (2048 frames at 48 kHz) is about two blocks; the
        // loop below drains anything beyond capacity regardless.
        let inputProvider = SonioxOpusInputProvider(buffer: pcm)
        var encoded = Data()
        while true {
            let output = AVAudioCompressedBuffer(
                format: flacFormat,
                packetCapacity: 8,
                maximumPacketSize: max(converter.maximumOutputPacketSize, 1)
            )
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputProvider.nextBuffer(inputStatus: inputStatus)
            }
            guard status != .error else { return nil }
            blocksEmitted += Int(output.packetCount)
            if let descriptions = output.packetDescriptions {
                for index in 0..<Int(output.packetCount) {
                    let packet = descriptions[index]
                    encoded.append(
                        output.data.advanced(by: Int(packet.mStartOffset))
                            .assumingMemoryBound(to: UInt8.self),
                        count: Int(packet.mDataByteSize)
                    )
                }
            }
            // `.haveData` means the output filled before the input ran out.
            guard status == .haveData else { break }
        }
        return encoded
    }

    /// `fLaC` and a STREAMINFO block marked as the last metadata block. Built here rather
    /// than taken from the converter's magic cookie, whose layout (an MP4 `dfLa` box) is
    /// Apple's to change.
    static func streamHeader(
        sampleRate: UInt32,
        channelCount: UInt8,
        bitsPerSample: UInt8,
        blockSize: UInt16
    ) -> Data {
        var header = Data("fLaC".utf8)
        // Last-metadata-block flag set, type 0 (STREAMINFO), 34-byte body.
        header.append(contentsOf: [0x80, 0x00, 0x00, 0x22])
        appendBigEndian(UInt64(blockSize), bytes: 2, to: &header)
        appendBigEndian(UInt64(blockSize), bytes: 2, to: &header)
        // Minimum and maximum frame size: 0, unknown.
        appendBigEndian(0, bytes: 3, to: &header)
        appendBigEndian(0, bytes: 3, to: &header)
        // 20-bit sample rate, 3-bit channels - 1, 5-bit bits per sample - 1, 36-bit total
        // samples (0, unknown for a live stream).
        let packed =
            UInt64(sampleRate) << 44
            | UInt64(channelCount - 1) << 41
            | UInt64(bitsPerSample - 1) << 36
        appendBigEndian(packed, bytes: 8, to: &header)
        // MD5 of the decoded audio: all zero means not computed.
        header.append(Data(count: 16))
        return header
    }

    private static func appendBigEndian(_ value: UInt64, bytes: Int, to data: inout Data) {
        for index in stride(from: bytes - 1, through: 0, by: -1) {
            data.append(UInt8(truncatingIfNeeded: value >> (8 * index)))
        }
    }
}

private final class SonioxOpusInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(
        inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard !didProvideInput else {
            // Not end of stream: the converter keeps any partial packet for the next call.
            inputStatus.pointee = .noDataNow
            return nil
        }
        didProvideInput = true
        inputStatus.pointee = .haveData
        return buffer
    }
}
