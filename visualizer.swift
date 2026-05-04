import Foundation
import Accelerate
import CoreAudio
import AppKit
import Network

// Config
struct Config {
    var numBands    : Int    = 119
    var fftSize     : Int    = 2048
    var fftOverlap  : Int    = 1024
    var freqMin     : Float  = 250.0
    var freqMax     : Float  = 16000.0
    var sensitivFast: Float  = 32.0
    var sensitivSlow: Float  = 40.0
    var bandGain    : Float  = 0.8    // pre-clamp boost (macOS tap is pre-volume)
    var decayFastMs    : Double = 250.0
    var decaySlowMs    : Double = 500.0
    var fadeOutFastMs  : Double = 50.0
    var fadeOutSlowMs  : Double = 80.0
    var port        : UInt16 = 9001

    // Derived
    // Rainmeter skips the first and last band (BandIdx 1-N out of N+2 total)
    var numBandsTotal: Int   { numBands + 2 }
    // vDSP gives 2x magnitude vs kiss_fftr -> 4x power; Rainmeter scalar = 1/sqrt(N)
    var binScalar    : Float { 1.0 / (4.0 * sqrt(Float(fftSize))) }
}

func findPID(bundleID: String) -> pid_t? {
    for app in NSWorkspace.shared.runningApplications {
        if app.bundleIdentifier == bundleID { return app.processIdentifier }
    }
    return nil
}

func findAudioObjectID(pid: pid_t) -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var propSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize) == noErr else { return nil }
    let count = Int(propSize) / MemoryLayout<AudioObjectID>.size
    var objects = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &objects) == noErr else { return nil }
    for obj in objects {
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var objPID: pid_t = 0
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &objPID) == noErr else { continue }
        if objPID == pid { return obj }
    }
    return nil
}

class AudioVisualizer {
    let config  : Config
    let wsServer = WebSocketServer()

    // CoreAudio objects (nil/0 when tap is inactive)
    var tapID       : AudioObjectID          = 0
    var aggDeviceID : AudioDeviceID          = 0
    var procID      : AudioDeviceIOProcID?   = nil
    var isCapturing : Bool                   = false

    // Device sample rate - queried after aggregate creation
    var sampleRate  : Double = 44100.0
    var kDecayFast  : Float  = 0.0
    var kDecaySlow  : Float  = 0.0

    // FFT state
    var log2n       : vDSP_Length
    var fftSetup    : FFTSetup?
    var hannWindow  : [Float]

    // Ring buffer for mono samples
    var ringBuf     : [Float]
    var ringWrite   : Int = 0
    var samplesIn   : Int = 0

    // Per-bin smoothed power (fast / slow), audio thread only
    var fastBins    : [Float]
    var slowBins    : [Float]

    // Band upper-frequency edges (computed from Rainmeter's log2-step formula)
    var bandFreq    : [Float]

    // Output arrays, lock-protected
    var fastBands   : [Float]
    var slowBands   : [Float]
    let lock        = NSLock()

    var isMusicPlaying: Bool = false
    var decayTimer    : DispatchSourceTimer?
    var debugTick     : Int  = 0

    // Pre-built idle binary frame (all zeros); built once, reused on every music pause
    lazy var idleBinary: Data = Data(count: config.numBands * 8)

    init(config: Config) {
        self.config = config
        log2n      = vDSP_Length(log2(Double(config.fftSize)))
        hannWindow = [Float](repeating: 0, count: config.fftSize)
        ringBuf    = [Float](repeating: 0, count: config.fftSize * 4)
        fastBins   = [Float](repeating: 0, count: config.fftSize / 2 + 1)
        slowBins   = [Float](repeating: 0, count: config.fftSize / 2 + 1)
        bandFreq   = [Float](repeating: 0, count: config.numBandsTotal)
        fastBands  = [Float](repeating: 0, count: config.numBands)
        slowBands  = [Float](repeating: 0, count: config.numBands)

        // Subscribe to Music.app playback state changes.
        // Music.app still uses the iTunes notification name for compatibility.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.iTunes.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let state = note.userInfo?["Player State"] as? String else { return }
            switch state {
            case "Playing", "Fast Forward", "Rewind":
                self.isMusicPlaying = true
                self.decayTimer?.cancel()
                self.decayTimer = nil
                self.startTapIfNeeded()
            case "Paused", "Stopped":
                self.isMusicPlaying = false
                if self.isCapturing { self.stopTap(animated: self.wsServer.hasClients) }
            default:
                break
            }
        }
    }

    func startTapIfNeeded() {
        guard !isCapturing, isMusicPlaying, wsServer.hasClients else { return }
        guard let pid = findPID(bundleID: "com.apple.Music") else {
            isMusicPlaying = false
            pushIdle()
            return
        }
        startTap(pid: pid)
    }

    func start() {
        wsServer.onClientCountChanged = { [weak self] count in
            guard let self = self else { return }
            if count == 0 {
                self.decayTimer?.cancel()
                self.decayTimer = nil
                if self.isCapturing { self.stopTap(animated: false) }
            } else {
                self.startTapIfNeeded()
                if !self.isMusicPlaying && !self.isCapturing { self.pushIdle() }
            }
        }
        wsServer.start(port: config.port)
        if findPID(bundleID: "com.apple.Music") != nil {
            isMusicPlaying = true
        } else {
            print("Music not running - polling every 2s")
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                if findPID(bundleID: "com.apple.Music") != nil {
                    t.invalidate()
                    self.isMusicPlaying = true
                }
            }
        }
    }

    func startTap(pid: pid_t) {
        guard !isCapturing else { return }

        guard let audioObjID = findAudioObjectID(pid: pid) else {
            print("Could not find audio object for pid \(pid)"); return
        }

        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [audioObjID])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted

        var tapObjectID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(tapDesc, &tapObjectID) == noErr else {
            print("Failed to create process tap"); return
        }
        tapID = tapObjectID

        let tapUID = tapDesc.uuid.uuidString
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey:      "VisualizerAgg",
            kAudioAggregateDeviceUIDKey:       "com.visualizer.agg.\(tapUID)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey:   [[
                kAudioSubTapUIDKey:               tapUID,
                kAudioSubTapDriftCompensationKey: false
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]

        var newAggID: AudioDeviceID = 0
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID) == noErr else {
            print("Failed to create aggregate device"); return
        }
        aggDeviceID = newAggID

        // Query actual sample rate (44100 or 48000 on most Macs)
        var actualRate: Float64 = 44100.0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(newAggID, &rateAddr, 0, nil, &rateSize, &actualRate)
        sampleRate = actualRate

        // Rainmeter decay: k = exp(log10(0.01) / (steps/sec * decay_ms * 0.001))
        let stepsPerSec = actualRate / Double(config.fftSize - config.fftOverlap)
        kDecayFast = Float(exp(log10(0.01) / (stepsPerSec * config.decayFastMs * 0.001)))
        kDecaySlow = Float(exp(log10(0.01) / (stepsPerSec * config.decaySlowMs  * 0.001)))
        print("Tap started - rate=\(Int(actualRate))Hz  steps/sec=\(Int(stepsPerSec))  kFast=\(String(format:"%.4f",kDecayFast))  kSlow=\(String(format:"%.4f",kDecaySlow))")

        // Band upper-frequency edges: Rainmeter log2-step spacing
        let step = log2(Double(config.freqMax) / Double(config.freqMin)) / Double(config.numBandsTotal)
        bandFreq[0] = config.freqMin * Float(pow(2.0, step / 2.0))
        for b in 1..<config.numBandsTotal {
            bandFreq[b] = bandFreq[b - 1] * Float(pow(2.0, step))
        }

        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        // Rainmeter Hann: w[i] = 0.5*(1-cos(2*pi*i/(N-1))) -> vDSP_HANN_DENORM
        vDSP_hann_window(&hannWindow, vDSP_Length(config.fftSize), Int32(vDSP_HANN_DENORM))

        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, newAggID, nil) {
            [weak self] (_, inInputData, _, _, _) in
            guard let self = self else { return }
            let abl = inInputData.pointee
            guard abl.mNumberBuffers > 0,
                  let data = abl.mBuffers.mData,
                  abl.mBuffers.mDataByteSize > 0 else { return }
            let ch     = Int(abl.mBuffers.mNumberChannels)
            let total  = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            let frames = total / max(1, ch)
            let ptr    = data.bindMemory(to: Float.self, capacity: total)
            self.ingest(ptr, frames: frames, channels: ch)
        }
        guard err == noErr, let proc = procID else {
            print("Failed to create IOProc: \(err)"); teardownDevices(); return
        }

        AudioDeviceStart(newAggID, proc)
        isCapturing = true
    }

    func stopTap(animated: Bool = false) {
        guard isCapturing else { return }
        isCapturing = false

        if let proc = procID {
            AudioDeviceStop(aggDeviceID, proc)
            AudioDeviceDestroyIOProcID(aggDeviceID, proc)
            procID = nil
        }
        teardownDevices()

        fastBins = [Float](repeating: 0, count: config.fftSize / 2 + 1)
        slowBins = [Float](repeating: 0, count: config.fftSize / 2 + 1)
        samplesIn = 0
        ringWrite = 0

        if animated {
            startDecayAnimation()
        } else {
            lock.lock()
            fastBands = [Float](repeating: 0, count: config.numBands)
            slowBands = [Float](repeating: 0, count: config.numBands)
            lock.unlock()
            pushIdle()
            print("Tap stopped")
        }
    }

    func startDecayAnimation() {
        let kFast = Float(exp(log10(0.01) / (60.0 * config.fadeOutFastMs * 0.001)))
        let kSlow = Float(exp(log10(0.01) / (60.0 * config.fadeOutSlowMs * 0.001)))
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            var maxVal: Float = 0
            for i in 0..<self.config.numBands {
                self.fastBands[i] *= kFast
                self.slowBands[i] *= kSlow
                if self.fastBands[i] > maxVal { maxVal = self.fastBands[i] }
            }
            self.lock.unlock()
            if maxVal < 0.001 {
                self.decayTimer?.cancel()
                self.decayTimer = nil
                self.lock.lock()
                self.fastBands = [Float](repeating: 0, count: self.config.numBands)
                self.slowBands = [Float](repeating: 0, count: self.config.numBands)
                self.lock.unlock()
                self.pushIdle()
                print("Tap stopped")
            } else {
                self.pushBands()
            }
        }
        timer.resume()
        decayTimer = timer
    }

    private func teardownDevices() {
        if aggDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggDeviceID)
            aggDeviceID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        if let s = fftSetup { vDSP_destroy_fftsetup(s); fftSetup = nil }
    }

    // Audio ingestion
    func ingest(_ ptr: UnsafePointer<Float>, frames: Int, channels: Int) {
        let hop = config.fftSize - config.fftOverlap
        for i in 0..<frames {
            var mono: Float = 0
            for c in 0..<channels { mono += ptr[i * channels + c] }
            mono /= Float(channels)
            ringBuf[ringWrite % ringBuf.count] = mono
            ringWrite += 1
            samplesIn += 1
            if samplesIn >= config.fftSize {
                processWindow()
                samplesIn -= hop
            }
        }
    }

    // FFT processing
    func processWindow() {
        guard let setup = fftSetup else { return }

        let n   = config.fftSize
        let end = ringWrite
        let beg = end - n
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n {
            frame[i] = ringBuf[((beg + i) % ringBuf.count + ringBuf.count) % ringBuf.count]
        }
        vDSP_vmul(frame, 1, hannWindow, 1, &frame, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)

        frame.withUnsafeMutableBufferPointer { fPtr in
            real.withUnsafeMutableBufferPointer { rPtr in
                imag.withUnsafeMutableBufferPointer { iPtr in
                    var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    fPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cPtr in
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(n / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                    let nyquist = n / 2
                    let binSc   = config.binScalar

                    // Step 1 - per-bin smoothing (Rainmeter order: before band integration)
                    // FFTAttack=0 -> instant attack; FFTDecay -> exponential fall
                    for bin in 1..<nyquist {
                        let r  = split.realp[bin], im = split.imagp[bin]
                        let x1 = (r * r + im * im) * binSc

                        if x1 >= self.fastBins[bin] { self.fastBins[bin] = x1 }
                        else { self.fastBins[bin] = x1 + self.kDecayFast * (self.fastBins[bin] - x1) }

                        if x1 >= self.slowBins[bin] { self.slowBins[bin] = x1 }
                        else { self.slowBins[bin] = x1 + self.kDecaySlow * (self.slowBins[bin] - x1) }
                    }

                    // Step 2 - frequency-weighted band integration (Rainmeter sweep)
                    let df         = Float(self.sampleRate) / Float(n)
                    let bandScalar = 2.0 / Float(self.sampleRate)
                    var fastBO     = [Float](repeating: 0, count: self.config.numBandsTotal)
                    var slowBO     = [Float](repeating: 0, count: self.config.numBandsTotal)

                    var iBin  = Int(roundf(self.config.freqMin / df))
                    var iBand = 0
                    var f0    = self.config.freqMin

                    while iBin <= nyquist && iBand < self.config.numBandsTotal {
                        let fLin1 = (Float(iBin) + 0.5) * df
                        let fLog1 = self.bandFreq[iBand]
                        let xF    = iBin < nyquist ? self.fastBins[iBin] : 0
                        let xS    = iBin < nyquist ? self.slowBins[iBin] : 0

                        if fLin1 <= fLog1 {
                            fastBO[iBand] += (fLin1 - f0) * xF * bandScalar
                            slowBO[iBand] += (fLin1 - f0) * xS * bandScalar
                            f0 = fLin1; iBin += 1
                        } else {
                            fastBO[iBand] += (fLog1 - f0) * xF * bandScalar
                            slowBO[iBand] += (fLog1 - f0) * xS * bandScalar
                            f0 = fLog1; iBand += 1
                        }
                    }

                    // Debug every ~7 s
                    self.debugTick += 1
                    if self.debugTick % 300 == 0 {
                        let mx  = fastBO[1..<self.config.numBandsTotal].max() ?? 0
                        let mxG = min(1.0, mx * self.config.bandGain)
                        let val = max(0, 10.0 / self.config.sensitivFast * log10f(mxG + 1e-10) + 1.0)
                        print("maxBandPow=\(String(format:"%.5f",mx))  gainClamped=\(String(format:"%.5f",mxG))  val=\(String(format:"%.3f",val))")
                    }

                    // Step 3 - Rainmeter sensitivity formula:
                    //   x = clamp01(bandOut * gain)
                    //   val = max(0, 10/sensitivity * log10(x) + 1)
                    // Output BandIdx 1..N (skip band 0 and band N+1, like Rainmeter)
                    self.lock.lock()
                    for b in 0..<self.config.numBands {
                        let fRaw = min(1.0, fastBO[b + 1] * self.config.bandGain)
                        let sRaw = min(1.0, slowBO[b + 1] * self.config.bandGain)
                        self.fastBands[b] = max(0, 10.0 / self.config.sensitivFast * log10f(fRaw + 1e-10) + 1.0)
                        self.slowBands[b] = max(0, 10.0 / self.config.sensitivSlow * log10f(sRaw + 1e-10) + 1.0)
                    }
                    self.lock.unlock()
                    DispatchQueue.main.async { [weak self] in self?.pushBands() }
                }
            }
        }
    }

    func pushBands() {
        guard wsServer.hasClients, wsServer.rendererActive else { return }
        wsServer.broadcast(buildBinary())
    }

    func pushIdle() {
        guard wsServer.hasClients else { return }
        wsServer.broadcast(idleBinary)
    }

    func buildBinary() -> Data {
        lock.lock()
        let f = fastBands, s = slowBands
        lock.unlock()
        var data = Data(capacity: config.numBands * 8)
        f.withUnsafeBytes { data.append(contentsOf: $0) }
        s.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

// --- WebSocket Server ---

class WebSocketServer {
    private var listener      : NWListener?
    private var connections   : [ObjectIdentifier: NWConnection] = [:]
    private var lastHeartbeat : Date = .distantPast
    var onClientCountChanged  : ((Int) -> Void)?

    // True if the renderer sent a heartbeat within the last 2 seconds.
    // Covers the case where the WebSocket stays open but WebKit is paused.
    var rendererActive: Bool { Date().timeIntervalSince(lastHeartbeat) < 2.0 }

    func start(port: UInt16) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let wsOpts = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            print("WebSocket server failed on port \(port)"); return
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: .main)
        listener = l
        print("WebSocket server on ws://127.0.0.1:\(port)")
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        onClientCountChanged?(connections.count)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: id)
                self?.onClientCountChanged?(self?.connections.count ?? 0)
            default: break
            }
        }
        receive(conn, id: id)
        conn.start(queue: .main)
    }

    private func receive(_ conn: NWConnection, id: ObjectIdentifier) {
        conn.receiveMessage { [weak self] _, ctx, _, err in
            guard let self = self else { return }
            if err != nil {
                self.connections.removeValue(forKey: id)
                conn.cancel()
                return
            }
            if let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                            as? NWProtocolWebSocket.Metadata,
               meta.opcode == .close {
                conn.cancel()
                return
            }
            self.lastHeartbeat = Date()
            self.receive(conn, id: id)
        }
    }

    func broadcast(_ data: Data) {
        guard !connections.isEmpty else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx  = NWConnection.ContentContext(identifier: "fft", metadata: [meta])
        for conn in connections.values {
            conn.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
        }
    }

    var hasClients: Bool { !connections.isEmpty }
}


let config     = Config()
let visualizer = AudioVisualizer(config: config)
visualizer.start()
RunLoop.main.run()
