import Foundation
import Combine
import Accelerate
import Metal
import CoreAudio
import AVFAudio

// MARK: - Audio Capture Engine
// Menggunakan CATapDescription (macOS 14.2+) — pure audio, tidak ada video pipeline.
// Jauh lebih ringan dari ScreenCaptureKit yang menjalankan video encoder di background.

class AudioCaptureEngine: NSObject, ObservableObject {

    // ── Published state ───────────────────────────────────────────────────
    let waveRenderer: WaveformMetalRenderer = {
        let dev = MTLCreateSystemDefaultDevice()!
        return WaveformMetalRenderer(device: dev)!
    }()

    // Peak meter (dBFS) — stereo, respons cepat seperti waveform
    @Published var peakL:     Float = -144.0
    @Published var peakR:     Float = -144.0
    @Published var peakHoldL: Float = -144.0
    @Published var peakHoldR: Float = -144.0
    // Short-term LUFS (satu-satunya yang menampilkan angka)
    @Published var lufsS:     Float = -144.0
    @Published var lufsSPeak: Float = -144.0
    @Published var isCapturing  = false
    @Published var errorMessage: String? = nil

    // ── Private (processingQueue only) ───────────────────────────────────
    private let lufsCalc = StereoLUFSCalculator(sampleRate: 48_000)
    private var peakLufsS: Float = -144
    // Peak-meter ballistics (dBFS): attack instan, release lambat
    private var meterL: Float = -144, meterR: Float = -144
    private var holdL:  Float = -144, holdR:  Float = -144
    private var accumL: [Float] = []
    private var accumR: [Float] = []
    private let chunkSize = 1024
    private var lufsUpdateAccum = 0
    private let lufsUpdateInterval = 48_000 / 24   // 24fps LUFS updates (lebih mulus)

    // ── CoreAudio tap objects ─────────────────────────────────────────────
    private var tapObjectID:       AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var audioEngine:       AVAudioEngine?

    // ── Startup watchdog ──────────────────────────────────────────────────
    // CoreAudio aggregate device + tap kadang belum "ready" saat engine start,
    // jadi audio tidak mengalir sampai di-restart. Watchdog deteksi ini dan
    // auto-restart, sehingga user tidak perlu klik Stop/Play manual.
    private var didReceiveAudio = false        // processingQueue only
    private var watchdogTask: Task<Void, Never>?
    private var restartAttempts = 0

    private let processingQueue = DispatchQueue(
        label: "audio.meter.processing", qos: .userInteractive)

    // MARK: Public API

    func start() async {
        guard !isCapturing else { return }
        do {
            try await launchCapture()
        } catch {
            await MainActor.run { self.errorMessage = error.localizedDescription }
        }
    }

    func toggle() async {
        if isCapturing { await stop() } else { await start() }
    }

    func stop() async {
        watchdogTask?.cancel()
        watchdogTask = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        if tapObjectID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        processingQueue.sync {
            self.accumL.removeAll()
            self.accumR.removeAll()
            self.peakLufsS = -144
            self.meterL = -144; self.meterR = -144
            self.holdL  = -144; self.holdR  = -144
            self.lufsUpdateAccum = 0
            self.didReceiveAudio = false
        }
        await MainActor.run { self.isCapturing = false }
    }

    // MARK: CATapDescription setup

    private func launchCapture() async throws {
        // 1. Global stereo process tap — pure audio, tidak ada video pipeline
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])

        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard tapStatus == noErr else {
            throw makeError("Cannot create audio tap (OSStatus \(tapStatus))")
        }
        tapObjectID = tapID

        // 2. Baca UID tap
        var uidRef: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        let uidStatus = AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, &uidRef)
        guard uidStatus == noErr, let tapUID = uidRef as String? else {
            throw makeError("Cannot read tap UID")
        }

        // 3. Buat private aggregate device yang wrap tap
        let aggUID = "com.audiometer.agg.\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceUIDKey:          aggUID,
            kAudioAggregateDeviceNameKey:         "AudioMeterAgg",
            kAudioAggregateDeviceIsPrivateKey:    true,
            kAudioAggregateDeviceTapListKey:      [[kAudioSubTapUIDKey: tapUID]],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]
        var aggID: AudioDeviceID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard aggStatus == noErr else {
            throw makeError("Cannot create aggregate device (OSStatus \(aggStatus))")
        }
        aggregateDeviceID = aggID

        // 3b. Beri CoreAudio waktu mem-publish aggregate device + tap.
        // Tanpa ini, engine kadang start sebelum device ready → audio diam.
        try? await Task.sleep(nanoseconds: 250_000_000)

        // 4. AVAudioEngine dengan aggregate device sebagai input
        let engine = AVAudioEngine()
        guard let au = engine.inputNode.audioUnit else {
            throw makeError("Cannot access input AudioUnit")
        }
        var devID = aggID
        let setStatus = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard setStatus == noErr else {
            throw makeError("Cannot set input device (OSStatus \(setStatus))")
        }

        // 5. Install audio tap — terima AVAudioPCMBuffer, proses di processingQueue
        let captureFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: captureFormat) {
            [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let n     = Int(buffer.frameLength)
            let left  = Array(UnsafeBufferPointer(start: data[0], count: n))
            let right = buffer.format.channelCount >= 2
                ? Array(UnsafeBufferPointer(start: data[1], count: n))
                : left
            self.processingQueue.async { self.processAudio(left: left, right: right) }
        }

        try engine.start()
        audioEngine = engine

        await MainActor.run {
            self.isCapturing  = true
            self.errorMessage = nil
        }

        startWatchdog()
    }

    // MARK: Startup watchdog

    /// Cek ~1.2 dtk setelah start: kalau belum ada audio masuk, auto-restart.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled, self.isCapturing else { return }

            let got = self.processingQueue.sync { self.didReceiveAudio }
            if got {
                self.restartAttempts = 0      // audio mengalir — sehat
                return
            }
            guard self.restartAttempts < 3 else {
                await MainActor.run {
                    self.errorMessage = "Tidak ada audio — klik Stop lalu Play"
                }
                return
            }
            self.restartAttempts += 1
            await self.stop()
            await self.start()                // start() akan pasang watchdog lagi
        }
    }

    // MARK: Audio processing

    private func processAudio(left: [Float], right: [Float]) {
        didReceiveAudio = true   // sinyal ke watchdog: audio mengalir

        // Short-term LUFS (cuma S yang dipakai untuk angka)
        let (_, ls) = lufsCalc.process(left: left, right: right)
        let lufsDecay = Float(15.0 * Double(left.count) / 48_000.0)
        peakLufsS = max(ls, peakLufsS - lufsDecay)

        // Peak meter (dBFS) per kanal — attack instan, release lambat (gaya PPM)
        var pkL: Float = 0, pkR: Float = 0
        left.withUnsafeBufferPointer  { vDSP_maxmgv($0.baseAddress!, 1, &pkL, vDSP_Length($0.count)) }
        right.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &pkR, vDSP_Length($0.count)) }
        let dbL = pkL > 1e-7 ? 20 * log10f(pkL) : -144
        let dbR = pkR > 1e-7 ? 20 * log10f(pkR) : -144
        let relDb  = Float(26.0 * Double(left.count) / 48_000.0)   // release ~26 dB/s
        let holdDb = Float(8.0  * Double(left.count) / 48_000.0)   // peak-hold turun lambat
        meterL = max(dbL, meterL - relDb);  meterR = max(dbR, meterR - relDb)
        holdL  = max(dbL, holdL  - holdDb); holdR  = max(dbR, holdR  - holdDb)

        lufsUpdateAccum += left.count
        if lufsUpdateAccum >= lufsUpdateInterval {
            lufsUpdateAccum = 0
            let s = ls, ps = peakLufsS
            let mL = meterL, mR = meterR, hL = holdL, hR = holdR
            DispatchQueue.main.async { [weak self] in
                self?.lufsS = s; self?.lufsSPeak = ps
                self?.peakL = mL; self?.peakR = mR
                self?.peakHoldL = hL; self?.peakHoldR = hR
            }
        }

        // Waveform bars — simpan min + max per chunk (vDSP SIMD, DAW-style)
        accumL.append(contentsOf: left)
        accumR.append(contentsOf: right)
        var minLArr: [Float] = [], maxLArr: [Float] = []
        var minRArr: [Float] = [], maxRArr: [Float] = []

        while accumL.count >= chunkSize {
            var minL = Float(0), maxL = Float(0)
            var minR = Float(0), maxR = Float(0)
            accumL.withUnsafeBufferPointer { ptr in
                vDSP_minv(ptr.baseAddress!, 1, &minL, vDSP_Length(chunkSize))
                vDSP_maxv(ptr.baseAddress!, 1, &maxL, vDSP_Length(chunkSize))
            }
            accumR.withUnsafeBufferPointer { ptr in
                vDSP_minv(ptr.baseAddress!, 1, &minR, vDSP_Length(chunkSize))
                vDSP_maxv(ptr.baseAddress!, 1, &maxR, vDSP_Length(chunkSize))
            }
            minLArr.append(minL); maxLArr.append(maxL)
            minRArr.append(minR); maxRArr.append(maxR)
            accumL.removeFirst(chunkSize)
            accumR.removeFirst(chunkSize)
        }
        if !minLArr.isEmpty {
            waveRenderer.pushBars(minL: minLArr, maxL: maxLArr,
                                  minR: minRArr, maxR: maxRArr)
        }
    }

    private func makeError(_ msg: String) -> Error {
        NSError(domain: "AudioMeter", code: -1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
