import Foundation

/// Maps a position in the audio one Soniox connection has received back to when that audio
/// was captured, so a token's `end_ms` or a processing watermark becomes a caption age.
///
/// Soniox times everything from the start of the stream it was sent, and each reconnect
/// starts a new stream at zero, so a timeline lives for one connection. Positions are
/// counted from the audio fed to the encoder rather than from bytes on the wire, which keeps
/// the mapping identical for PCM, Opus and FLAC; a compressing encoder holding its last
/// partial packet puts it at most one packet ahead of what Soniox has.
///
/// Capture time is when the tap delivered the buffer, which is when its *last* sample was
/// captured plus the device's I/O latency. Ages measured against it are therefore slightly
/// short, by that latency, for every encoding alike.
struct SonioxStreamTimeline {
    private struct Span {
        let startMicroseconds: Int64
        let endMicroseconds: Int64
        let capturedAt: ContinuousClock.Instant
    }

    /// About 90 seconds of 1,024-frame buffers at 48 kHz. Spans are normally discarded as
    /// Soniox finalizes, so this only matters if finalization stalls; then the oldest go and
    /// lookups that far back report no age rather than growing memory.
    static let maximumSpans = 4_096

    private var spans: [Span] = []
    private var head = 0
    private(set) var fedMicroseconds: Int64 = 0

    mutating func append(duration: Duration, capturedAt: ContinuousClock.Instant) {
        let length = duration.wholeMicroseconds
        guard length > 0 else { return }
        spans.append(
            Span(
                startMicroseconds: fedMicroseconds,
                endMicroseconds: fedMicroseconds + length,
                capturedAt: capturedAt
            )
        )
        fedMicroseconds += length
        if spans.count - head > Self.maximumSpans {
            head = spans.count - Self.maximumSpans
        }
        compactIfNeeded()
    }

    /// When the audio at `streamMilliseconds` was captured, or nil if that position has been
    /// discarded or was never sent.
    func capturedAt(streamMilliseconds: Int) -> ContinuousClock.Instant? {
        let target = Int64(streamMilliseconds) * 1_000
        guard head < spans.count,
            target >= spans[head].startMicroseconds,
            target <= fedMicroseconds
        else {
            return nil
        }
        var low = head
        var high = spans.count - 1
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].endMicroseconds < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let span = spans[low]
        return span.capturedAt - .microseconds(span.endMicroseconds - target)
    }

    /// Drops audio wholly before `streamMilliseconds`. Called with Soniox's finalized
    /// watermark: no later token can start before it.
    mutating func discard(before streamMilliseconds: Int) {
        let target = Int64(streamMilliseconds) * 1_000
        while head < spans.count, spans[head].endMicroseconds < target {
            head += 1
        }
        compactIfNeeded()
    }

    private mutating func compactIfNeeded() {
        guard head >= 1_024, head * 2 >= spans.count else { return }
        spans.removeFirst(head)
        head = 0
    }
}

/// Bucketed durations, kept as counts so runs can be combined by adding buckets instead of
/// averaging percentiles. Quantiles are reported as the upper bound of the bucket they fall
/// in, clamped to the largest value seen.
struct LatencyHistogram: Equatable {
    static let boundsMilliseconds = [10, 20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 30_000]

    /// One more than the bounds: the last bucket holds everything above 30 s.
    private(set) var counts = [Int](repeating: 0, count: boundsMilliseconds.count + 1)
    private(set) var count = 0
    private(set) var maximumMilliseconds = 0

    mutating func record(_ duration: Duration) {
        record(milliseconds: Int(max(0, duration.wholeMicroseconds) / 1_000))
    }

    mutating func record(milliseconds: Int) {
        let value = max(0, milliseconds)
        let index =
            Self.boundsMilliseconds.firstIndex { value <= $0 } ?? Self.boundsMilliseconds.count
        counts[index] += 1
        count += 1
        maximumMilliseconds = max(maximumMilliseconds, value)
    }

    mutating func merge(_ other: LatencyHistogram) {
        for index in counts.indices {
            counts[index] += other.counts[index]
        }
        count += other.count
        maximumMilliseconds = max(maximumMilliseconds, other.maximumMilliseconds)
    }

    func quantileMilliseconds(_ quantile: Double) -> Int? {
        guard count > 0 else { return nil }
        let rank = max(1, Int((quantile * Double(count)).rounded(.up)))
        var seen = 0
        for (index, bucketCount) in counts.enumerated() {
            seen += bucketCount
            guard seen >= rank else { continue }
            guard index < Self.boundsMilliseconds.count else { return maximumMilliseconds }
            return min(Self.boundsMilliseconds[index], maximumMilliseconds)
        }
        return maximumMilliseconds
    }

    /// `le10:3,le20:0,…,inf:1`: the raw buckets, for combining runs later.
    var bucketDescription: String {
        let labels = Self.boundsMilliseconds.map { "le\($0)" } + ["inf"]
        return zip(labels, counts).map { "\($0):\($1)" }.joined(separator: ",")
    }

    /// Fields under a common prefix. Absent entirely when nothing was measured, so a missing
    /// measurement never reads as a zero.
    func fields(prefix: String) -> [String: String] {
        guard count > 0 else { return ["\(prefix)_count": "0"] }
        return [
            "\(prefix)_count": String(count),
            "\(prefix)_p50_ms": String(quantileMilliseconds(0.5) ?? 0),
            "\(prefix)_p95_ms": String(quantileMilliseconds(0.95) ?? 0),
            "\(prefix)_p99_ms": String(quantileMilliseconds(0.99) ?? 0),
            "\(prefix)_max_ms": String(maximumMilliseconds),
            "\(prefix)_hist": bucketDescription,
        ]
    }
}

/// What the uplink cost over an interval: the evidence for comparing encodings on bandwidth,
/// device CPU, and how long audio waited before it left the phone.
struct SonioxSendWindow {
    /// Capture buffers fed to the encoder.
    var frames = 0
    var audioDuration: Duration = .zero
    /// WebSocket messages sent. Fewer than `frames` when the encoder holds partial packets.
    var sends = 0
    var bytes = 0
    var encodeDuration: Duration = .zero
    var longestEncode: Duration = .zero
    /// Time `sendAudio` took to return, which is URLSession accepting the message, not the
    /// server receiving it.
    var longestSend: Duration = .zero
    /// From the tap delivering a buffer to the sender picking it up: backlog in the
    /// capture-to-sender queue, which is where a slow uplink shows up first.
    var queueAge = LatencyHistogram()
    var droppedDisconnected: Duration = .zero
    var conversionFailures = 0

    mutating func recordFrame(audioDuration: Duration, encode: Duration, queueAge: Duration) {
        frames += 1
        self.audioDuration += audioDuration
        encodeDuration += encode
        longestEncode = max(longestEncode, encode)
        self.queueAge.record(queueAge)
    }

    mutating func recordSend(bytes: Int, send: Duration) {
        sends += 1
        self.bytes += bytes
        longestSend = max(longestSend, send)
    }

    mutating func merge(_ other: SonioxSendWindow) {
        frames += other.frames
        audioDuration += other.audioDuration
        sends += other.sends
        bytes += other.bytes
        encodeDuration += other.encodeDuration
        longestEncode = max(longestEncode, other.longestEncode)
        longestSend = max(longestSend, other.longestSend)
        queueAge.merge(other.queueAge)
        droppedDisconnected += other.droppedDisconnected
        conversionFailures += other.conversionFailures
    }

    var isEmpty: Bool {
        frames == 0 && sends == 0 && droppedDisconnected == .zero && conversionFailures == 0
    }

    func fields() -> [String: String] {
        let audioMilliseconds = audioDuration.wholeMicroseconds / 1_000
        var fields = queueAge.fields(prefix: "queue_age")
        fields.merge([
            "frames": String(frames),
            "sends": String(sends),
            "audio_ms": String(audioMilliseconds),
            "bytes": String(bytes),
            // Over audio time, not wall time, so it is the encoding's rate however long
            // the window happened to be.
            "kbps": audioMilliseconds > 0 ? String(Int64(bytes) * 8 / audioMilliseconds) : "unavailable",
            "encode_ms": String(encodeDuration.wholeMicroseconds / 1_000),
            "encode_max_us": String(longestEncode.wholeMicroseconds),
            "send_max_ms": String(longestSend.wholeMicroseconds / 1_000),
            "dropped_disconnected_ms": String(droppedDisconnected.wholeMicroseconds / 1_000),
            "conversion_failures": String(conversionFailures),
        ]) { _, new in new }
        return fields
    }
}

/// Freshness of what Soniox returns, judged against when the audio was captured.
struct SonioxFreshness {
    /// Captions this far behind are stale enough that a reader notices. Measured from the
    /// processing watermark, which advances through silence too, so a quiet room does not
    /// count as stale.
    static let staleThreshold: Duration = .seconds(3)

    /// Capture to now for the newest audio Soniox has processed.
    var processedAge = LatencyHistogram()
    /// Capture to now for the newest audio Soniox has finalized.
    var finalizedAge = LatencyHistogram()
    /// Capture to now for the end of the newest word on screen, final or not.
    var visibleTokenAge = LatencyHistogram()
    /// Capture to now for the end of the newest word just finalized.
    var finalTokenAge = LatencyHistogram()

    private(set) var staleSince: ContinuousClock.Instant?
    private(set) var staleIntervals = 0
    private(set) var staleTotal: Duration = .zero
    private(set) var staleWorst: Duration = .zero

    enum StaleTransition: Equatable {
        case began
        case ended(duration: Duration, worstAge: Duration)
    }

    /// Updates the stale state from a new processed age, returning a change worth logging.
    mutating func observe(processedAge age: Duration, at now: ContinuousClock.Instant) -> StaleTransition? {
        if age > Self.staleThreshold {
            staleWorst = max(staleWorst, age)
            guard staleSince == nil else { return nil }
            staleSince = now
            staleIntervals += 1
            return .began
        }
        return endStale(at: now)
    }

    /// Closes an open stale interval, e.g. when the connection drops and the outage is
    /// accounted separately.
    mutating func endStale(at now: ContinuousClock.Instant) -> StaleTransition? {
        guard let since = staleSince else { return nil }
        let duration = since.duration(to: now)
        staleSince = nil
        staleTotal += duration
        let worst = staleWorst
        staleWorst = .zero
        return .ended(duration: duration, worstAge: worst)
    }

    func fields() -> [String: String] {
        var fields: [String: String] = [
            "stale_intervals": String(staleIntervals),
            "stale_ms": String(staleTotal.wholeMicroseconds / 1_000),
        ]
        for (prefix, histogram) in [
            ("processed_age", processedAge),
            ("finalized_age", finalizedAge),
            ("visible_token_age", visibleTokenAge),
            ("final_token_age", finalTokenAge),
        ] {
            fields.merge(histogram.fields(prefix: prefix)) { _, new in new }
        }
        return fields
    }
}

extension Duration {
    var wholeMicroseconds: Int64 {
        components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
    }
}
