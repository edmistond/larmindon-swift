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
}

enum SonioxWireEncoders {
    /// Falls back to PCM if the platform's Opus encoder can't be created, so a missing codec
    /// costs bandwidth rather than captions.
    static func make(
        for encoding: SonioxAudioEncoding,
        opusBitRate: SonioxOpusBitRate = SonioxOpusBitRate.defaultValue
    ) -> any SonioxWireEncoder {
        switch encoding {
        case .pcm:
            return SonioxPCMConverter()
        case .opus:
            return SonioxOpusEncoder(bitRate: opusBitRate) ?? SonioxPCMConverter()
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
        ]
    }

    func startStream() -> Data {
        lock.lock()
        defer { lock.unlock() }
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
