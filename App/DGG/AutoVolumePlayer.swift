import AVFoundation
import OSLog

/// Plays a live stream's sound itself, through a compressor, for Auto volume.
///
/// AVPlayer keeps the audio of a live HLS stream to itself: an audio processing
/// tap attaches without complaint and is never called. So for audio only this
/// fetches the playlists and segments, takes the AAC out of the MPEG-TS, decodes
/// it and plays it through AVAudioEngine, with the compressor in between.
///
/// Built for Kick and Twitch, whose segments are MPEG-TS with AAC. It keeps
/// trying through lost signal on its own, and steps down a rendition when
/// segments arrive slower than they play.
final class AutoVolumePlayer: @unchecked Sendable {
    private static let log = Logger(subsystem: "DGGTV", category: "autovolume")

    /// On the main actor: whether sound is coming out.
    var onPlaying: (@MainActor (Bool) -> Void)?
    /// On the main actor: the audio route was rebuilt (a CarPlay or Bluetooth
    /// change), which drops what was queued, so the stream should start again.
    var onRestartNeeded: (@MainActor () -> Void)?
    /// On the main actor: headphones or the car went away. Players pause then.
    var onRouteLost: (@MainActor () -> Void)?
    /// On the main actor: segments arrive but hold no audio this can read, so
    /// the stream should go back to AVPlayer.
    var onUnsupported: (@MainActor () -> Void)?
    private var empty = 0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let lock = NSLock()
    private var loop: Task<Void, Never>?
    private var generation = 0
    private var queued = 0.0
    private var paused = false
    private var reportedPlaying = false
    private var pcmFormat: AVAudioFormat?
    private var decoder: AACDecoder?
    private var compressor = Compressor()
    private var observers: [NSObjectProtocol] = []

    init() {
        engine.attach(node)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: engine, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            Self.log.notice("audio route rebuilt")
            MainActor.assumeIsolated { self.onRestartNeeded?() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            guard let self, self.isRunning, reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self.onRouteLost?() }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private var isRunning: Bool { lock.withLock { loop != nil } }

    /// `cap` is the highest bandwidth to choose; `cushion` starts at the oldest
    /// part the playlist still has, for a reserve against dead spots.
    func start(master: URL, cap: Double, cushion: Bool) {
        stop()
        let gen = lock.withLock { generation += 1; paused = false; return generation }
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.run(master: master, cap: cap, cushion: cushion, gen: gen)
        }
        lock.withLock { loop = task }
    }

    func stop() {
        let task: Task<Void, Never>? = lock.withLock {
            generation += 1
            let t = loop
            loop = nil
            queued = 0
            return t
        }
        task?.cancel()
        node.stop()
        engine.stop()
        engine.disconnectNodeOutput(node)
        pcmFormat = nil
        decoder = nil
        compressor = Compressor()
        empty = 0
        report()
    }

    func pause() {
        lock.withLock { paused = true }
        node.pause()
        report()
    }

    func resume() {
        lock.withLock { paused = false }
        if !engine.isRunning { try? engine.start() }
        node.play()
        report()
    }

    // MARK: - Fetching

    private struct Variant {
        let url: URL
        let bandwidth: Double
        let audioOnly: Bool
    }

    private struct Segment {
        let url: URL
        let duration: Double
    }

    private struct MediaPlaylist {
        let firstSeq: Int
        let segments: [Segment]
        let target: Double
        var lastSeq: Int { firstSeq + segments.count - 1 }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await Self.session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private func variants(_ master: URL) async throws -> [Variant] {
        let text = String(decoding: try await fetch(master), as: UTF8.self)
        guard text.contains("#EXT-X-STREAM-INF") else {
            return [Variant(url: master, bandwidth: 0, audioOnly: false)]
        }
        var out: [Variant] = []
        var pending: String?
        for line in text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pending = line
            } else if let info = pending, !line.isEmpty, !line.hasPrefix("#"),
                      let url = URL(string: line, relativeTo: master)?.absoluteURL {
                let bw = info.range(of: "BANDWIDTH=").map { r in
                    Double(info[r.upperBound...].prefix { $0.isNumber }) ?? 0
                } ?? 0
                let audio = info.contains("audio_only") || line.contains("audio_only")
                    || (info.contains("CODECS=\"mp4a") && !info.contains("avc1"))
                out.append(Variant(url: url, bandwidth: bw, audioOnly: audio))
                pending = nil
            }
        }
        return out.sorted { $0.bandwidth < $1.bandwidth }
    }

    /// An audio-only rendition if there is one, otherwise the most the cap allows.
    private static func choose(_ list: [Variant], cap: Double) -> Int {
        if let i = list.firstIndex(where: \.audioOnly) { return i }
        return list.lastIndex { $0.bandwidth <= cap } ?? 0
    }

    private func media(_ url: URL) async throws -> MediaPlaylist {
        let text = String(decoding: try await fetch(url), as: UTF8.self)
        var first = 0
        var target = 2.0
        var segments: [Segment] = []
        var duration: Double?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                first = Int(line.dropFirst(22)) ?? 0
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                target = Double(line.dropFirst(22)) ?? target
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).prefix { $0 != "," })
            } else if !line.isEmpty, !line.hasPrefix("#"), let d = duration,
                      let u = URL(string: line, relativeTo: url)?.absoluteURL {
                segments.append(Segment(url: u, duration: d))
                duration = nil
            }
        }
        return MediaPlaylist(firstSeq: first, segments: segments, target: target)
    }

    private func current(_ gen: Int) -> Bool {
        lock.withLock { gen == generation } && !Task.isCancelled
    }

    private func run(master: URL, cap: Double, cushion: Bool, gen: Int) async {
        var list: [Variant] = []
        var level = 0
        var top = 0
        var next: Int?
        var slow = 0
        var fast = 0
        var failures = 0
        while current(gen) {
            do {
                if list.isEmpty {
                    list = try await variants(master)
                    guard !list.isEmpty else { throw URLError(.cannotParseResponse) }
                    level = Self.choose(list, cap: cap)
                    top = level
                    Self.log.notice("rendition \(level + 1) of \(list.count), \(Int(list[level].bandwidth / 1000)) kbps")
                }
                let playlist = try await media(list[level].url)
                guard current(gen), !playlist.segments.isEmpty else { continue }
                failures = 0
                if next == nil || next! < playlist.firstSeq || next! > playlist.lastSeq + 1 {
                    next = playlist.firstSeq + Self.startIndex(playlist, cushion: cushion)
                }
                var fetched = false
                var switched = false
                while let seq = next, seq <= playlist.lastSeq, current(gen) {
                    // Far enough ahead already: let it play down.
                    while lock.withLock({ queued }) > 45, current(gen) {
                        try await Task.sleep(for: .seconds(1))
                    }
                    let segment = playlist.segments[seq - playlist.firstSeq]
                    let began = Date()
                    let data = try await fetch(segment.url)
                    guard current(gen) else { return }
                    let took = Date().timeIntervalSince(began)
                    try play(data, gen: gen)
                    next = seq + 1
                    fetched = true

                    // Arriving slower than it plays means the signal can't carry
                    // this rendition. Media sequence numbers line up between
                    // renditions, so the next one picks up where this left off.
                    if took > segment.duration * 0.8 { slow += 1; fast = 0 }
                    else if took < segment.duration * 0.3 { fast += 1; slow = 0 }
                    else { slow = 0; fast = 0 }
                    if slow >= 2, level > 0, !list[level].audioOnly {
                        level -= 1; slow = 0; switched = true
                        Self.log.notice("slow, down to \(Int(list[level].bandwidth / 1000)) kbps")
                        break
                    }
                    if fast >= 10, level < top {
                        level += 1; fast = 0; switched = true
                        Self.log.notice("fast, up to \(Int(list[level].bandwidth / 1000)) kbps")
                        break
                    }
                }
                if !fetched, !switched {
                    try await Task.sleep(for: .seconds(max(0.5, playlist.target / 2)))
                }
            } catch {
                guard current(gen) else { return }
                failures += 1
                if failures == 1 { Self.log.notice("lost the stream, retrying: \(error.localizedDescription)") }
                // Gone long enough to have left the playlist: start again from
                // the top, which also picks a fresh rendition.
                if failures % 6 == 0 { list = [] }
                try? await Task.sleep(for: .seconds(min(pow(2, Double(min(failures, 4))), 10)))
            }
        }
    }

    /// Near live: enough segments back to cover about 6s. With a cushion: the
    /// second oldest, so the oldest can drop off while it's fetched.
    private static func startIndex(_ playlist: MediaPlaylist, cushion: Bool) -> Int {
        let count = playlist.segments.count
        if cushion { return min(1, count - 1) }
        var covered = 0.0
        var i = count
        while i > 0, covered < 6 {
            i -= 1
            covered += playlist.segments[i].duration
        }
        return i
    }

    // MARK: - Decoding and playing

    private func play(_ segment: Data, gen: Int) throws {
        let adts = TransportStream.audio(in: segment)
        let frames = ADTS.frames(in: adts)
        guard let first = frames.first else {
            empty += 1
            if empty == 3 {
                Self.log.error("no AAC in three segments in a row")
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onUnsupported?() }
                }
            }
            return
        }
        empty = 0
        if decoder == nil || decoder?.matches(first.config) == false {
            decoder = try AACDecoder(config: first.config)
            try prepareEngine(for: decoder!.output)
        }
        guard let decoder, let buffer = try decoder.decode(frames), current(gen) else { return }
        compressor.process(buffer)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        lock.withLock { queued += seconds }
        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            let stillCurrent = self.lock.withLock { () -> Bool in
                guard gen == self.generation else { return false }
                self.queued = max(0, self.queued - seconds)
                return true
            }
            if stillCurrent { self.report() }
        }
        report()
    }


    private func prepareEngine(for format: AVAudioFormat) throws {
        if pcmFormat == format, engine.isRunning { return }
        node.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        pcmFormat = format
        compressor = Compressor(sampleRate: format.sampleRate)
        try? AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
        if !lock.withLock({ paused }) { node.play() }
    }

    private func report() {
        let changed: Bool? = lock.withLock {
            let playing = !paused && queued > 0.05 && loop != nil
            guard playing != reportedPlaying else { return nil }
            reportedPlaying = playing
            return playing
        }
        guard let playing = changed else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onPlaying?(playing) }
        }
    }
}

// MARK: - MPEG-TS

/// Pulls the audio elementary stream out of a TS segment: every 188-byte packet
/// carrying the PID whose PES headers mark it as audio, headers removed.
enum TransportStream {
    static func audio(in data: Data) -> Data {
        var out = Data()
        var audioPID: Int?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 188 <= b.count {
                defer { i += 188 }
                guard b[i] == 0x47 else { continue }
                let start = b[i + 1] & 0x40 != 0
                let pid = Int(b[i + 1] & 0x1F) << 8 | Int(b[i + 2])
                let control = (b[i + 3] >> 4) & 0x3
                guard control & 0x1 != 0 else { continue }
                var p = i + 4
                if control & 0x2 != 0 { p += 1 + Int(b[i + 4]) }
                guard p < i + 188 else { continue }
                if start, p + 9 <= i + 188, b[p] == 0, b[p + 1] == 0, b[p + 2] == 1 {
                    let streamID = b[p + 3]
                    if (0xC0...0xDF).contains(streamID), audioPID == nil { audioPID = pid }
                    guard pid == audioPID else { continue }
                    p += 9 + Int(b[p + 8])
                    guard p <= i + 188 else { continue }
                } else if pid != audioPID {
                    continue
                }
                out.append(contentsOf: UnsafeBufferPointer(rebasing: b[p..<(i + 188)]))
            }
        }
        return out
    }
}

// MARK: - AAC

enum ADTS {
    struct Config: Equatable {
        let objectType: UInt8
        let frequencyIndex: UInt8
        let channels: UInt8
        var sampleRate: Double {
            let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000,
                                   22050, 16000, 12000, 11025, 8000, 7350]
            return Int(frequencyIndex) < rates.count ? rates[Int(frequencyIndex)] : 48000
        }
    }

    struct Frame {
        let config: Config
        let payload: Data
    }

    static func frames(in data: Data) -> [Frame] {
        var out: [Frame] = []
        let b = [UInt8](data)
        var i = 0
        while i + 7 <= b.count {
            guard b[i] == 0xFF, b[i + 1] & 0xF0 == 0xF0 else { i += 1; continue }
            let protectionAbsent = b[i + 1] & 0x01 == 1
            let header = protectionAbsent ? 7 : 9
            let length = (Int(b[i + 3] & 0x03) << 11) | (Int(b[i + 4]) << 3) | Int(b[i + 5] >> 5)
            guard length > header, i + length <= b.count else { break }
            let config = Config(objectType: (b[i + 2] >> 6) + 1,
                                frequencyIndex: (b[i + 2] >> 2) & 0x0F,
                                channels: ((b[i + 2] & 0x01) << 2) | (b[i + 3] >> 6))
            out.append(Frame(config: config, payload: Data(b[(i + header)..<(i + length)])))
            i += length
        }
        return out
    }
}

/// Raw AAC frames to float PCM. One decoder for the whole stream, so frames
/// carry on smoothly from one segment to the next.
final class AACDecoder {
    let output: AVAudioFormat
    private let input: AVAudioFormat
    private let converter: AVAudioConverter
    private let config: ADTS.Config

    init(config: ADTS.Config) throws {
        self.config = config
        var description = AudioStreamBasicDescription(
            mSampleRate: config.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(config.channels),
            mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate,
                                         channels: AVAudioChannelCount(config.channels)),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw URLError(.cannotDecodeContentData)
        }
        // AudioSpecificConfig, which an ADTS header carries and raw frames don't.
        let asc = UInt16(config.objectType) << 11 | UInt16(config.frequencyIndex) << 7
            | UInt16(config.channels) << 3
        converter.magicCookie = Data([UInt8(asc >> 8), UInt8(asc & 0xFF)])
        self.input = input
        self.output = output
        self.converter = converter
    }

    func matches(_ other: ADTS.Config) -> Bool { other == config }

    func decode(_ frames: [ADTS.Frame]) throws -> AVAudioPCMBuffer? {
        guard !frames.isEmpty else { return nil }
        let total = frames.reduce(0) { $0 + $1.payload.count }
        let packets = AVAudioCompressedBuffer(format: input, packetCapacity: AVAudioPacketCount(frames.count),
                                              maximumPacketSize: max(total, 1))
        var offset = 0
        for (n, frame) in frames.enumerated() {
            frame.payload.withUnsafeBytes { src in
                packets.data.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: frame.payload.count)
            }
            packets.packetDescriptions![n] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset), mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(frame.payload.count))
            offset += frame.payload.count
        }
        packets.packetCount = AVAudioPacketCount(frames.count)
        packets.byteLength = UInt32(total)

        guard let pcm = AVAudioPCMBuffer(pcmFormat: output,
                                         frameCapacity: AVAudioFrameCount(frames.count * 1024)) else { return nil }
        var handed = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, state in
            if handed {
                state.pointee = .noDataNow
                return nil
            }
            handed = true
            state.pointee = .haveData
            return packets
        }
        if status == .error { throw error ?? URLError(.cannotDecodeContentData) }
        return pcm.frameLength > 0 ? pcm : nil
    }
}

// MARK: - Compressor

/// The same settings as Compresstiny's Auto volume, which ran in the browser on
/// a Web Audio compressor: threshold -34 dB, 12 dB knee, 6:1, 4 ms attack, 250 ms
/// release, then 2.2x. Web Audio also adds its own makeup, about +17 dB at these
/// settings, so the total here is +24 dB. Stereo-linked, so the image doesn't
/// wander, with a soft limit at the end for the peaks the attack lets through.
struct Compressor {
    var threshold: Float = -34
    var knee: Float = 12
    var ratio: Float = 6
    var makeup: Float = 24
    private var envelope: Float = 0
    private let attack: Float
    private let release: Float

    init(sampleRate: Double = 48000) {
        attack = exp(-1 / Float(0.004 * sampleRate))
        release = exp(-1 / Float(0.25 * sampleRate))
    }

    private func curve(_ x: Float) -> Float {
        let over = x - threshold
        if 2 * over < -knee { return x }
        if 2 * abs(over) <= knee {
            let t = over + knee / 2
            return x + (1 / ratio - 1) * t * t / (2 * knee)
        }
        return threshold + over / ratio
    }

    mutating func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.format.channelCount)
        for i in 0..<Int(buffer.frameLength) {
            var peak: Float = 0
            for c in 0..<count { peak = max(peak, abs(channels[c][i])) }
            let level = 20 * log10(max(peak, 1e-6))
            let reduction = curve(level) - level
            let coefficient = reduction < envelope ? attack : release
            envelope = coefficient * envelope + (1 - coefficient) * reduction
            let gain = pow(10, (envelope + makeup) / 20)
            for c in 0..<count {
                let v = channels[c][i] * gain
                // Soft limit above 0.8, tending to 1.
                let a = abs(v)
                channels[c][i] = a <= 0.8 ? v : (v < 0 ? -1 : 1) * (0.8 + 0.2 * tanh((a - 0.8) / 0.2))
            }
        }
    }
}
