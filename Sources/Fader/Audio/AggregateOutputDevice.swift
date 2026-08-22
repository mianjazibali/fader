import Foundation
import CoreAudio
import AudioToolbox

/// Slot in the gain table — one per active app, indexed by tap order.
/// Float reads/writes are atomic on aligned 32-bit boundaries — IOProc reads
/// without locks; stale reads of at most one buffer (~10ms) are fine.
final class GainSlot {
    private(set) var gain: Float = 1.0
    private let pointer: UnsafeMutablePointer<Float>
    private let levelPointer: UnsafeMutablePointer<Float>

    init(pointer: UnsafeMutablePointer<Float>, levelPointer: UnsafeMutablePointer<Float>) {
        self.pointer = pointer
        self.levelPointer = levelPointer
        pointer.pointee = 1.0
        levelPointer.pointee = 0
    }

    func setGain(_ value: Float) {
        let clamped = max(0, min(2, value))  // allow modest boost (>1.0)
        gain = clamped
        pointer.pointee = clamped
    }

    /// Most recent peak |sample| seen on this app's tap input, pre-gain,
    /// updated every IOProc cycle (~10ms) by the realtime capture callback.
    /// Real audio-derived level, not simulated — the UI's pulse loop reads
    /// this and applies its own attack/release smoothing for display.
    var level: Float { levelPointer.pointee }
}

/// **CAPTURE half of Phase 3.**
///
/// Builds a private aggregate device containing per-app process taps.
/// Apps that are tapped have their audio silenced from the normal output
/// path (via `CATapMutedWhenTapped`) and routed to us. Our IOProc:
///   1. Reads each tap's input buffer
///   2. Applies per-app gain
///   3. Mixes all taps into a single stereo stream
///   4. Writes that stream to the ring buffer
///
/// The playback half (`PlaybackDevice`) reads from the ring buffer on the
/// user's default output device's IOProc and mixes into the speakers.
final class AggregateOutputDevice {
    let aggregateID: AudioObjectID
    private(set) var ioProcID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    /// Per-tap gain slots in the same order taps were passed at init.
    let gainSlots: [GainSlot]
    private let gainBuffer: UnsafeMutableBufferPointer<Float>
    /// Per-tap peak levels — same order/indexing as gainBuffer, written by
    /// the realtime callback, exposed via GainSlot.level.
    private let levelBuffer: UnsafeMutableBufferPointer<Float>
    /// Per-tap gain actually *applied* right now — realtime-thread-owned
    /// only (never touched from the main thread), ramped toward
    /// `gainBuffer`'s target at a fixed max rate every sample instead of
    /// jumping instantly. An instant gain step (mute, or any fast slider
    /// move) is a discontinuity in the waveform — audible as a click/pop.
    /// A ~7ms linear ramp is fast enough to feel instant but long enough
    /// to not click.
    private let smoothedGainBuffer: UnsafeMutableBufferPointer<Float>

    /// Which slots get the call AGC (see `agcEnvelopeBuffer` below) — set
    /// once at init from each tap's source app, never mutated afterward.
    /// A plain Swift array is fine to capture into the realtime block:
    /// reading `boosted[i]` doesn't allocate.
    private let callBoosted: [Bool]

    /// Per-tap slow peak-follower envelope, realtime-thread-owned, used
    /// only for slots where `callBoosted[i]` is true. Call audio reads back
    /// much quieter than its untapped path (see CoreAudioEngine's comment
    /// on why a flat multiplier can't fix this) — this tracks each tap's
    /// recent peak level and derives an adaptive gain that pushes quiet
    /// passages up toward a target level while automatically backing off
    /// as the signal gets louder, instead of a fixed boost that's either
    /// too quiet on quiet passages or clips on loud ones.
    private let agcEnvelopeBuffer: UnsafeMutableBufferPointer<Float>

    /// Output ring buffer shared with the playback IOProc.
    private let ringBuffer: FloatRingBuffer

    /// Frame counters (IOProc updates atomically).
    /// Layout: [0]=tap-frames-in, [1]=samples-written-to-ring, [2]=ring-overruns.
    private let counterBuffer: UnsafeMutableBufferPointer<UInt64>

    var framesReceived: UInt64 { counterBuffer[0] }
    var samplesToRing:  UInt64 { counterBuffer[1] }
    var ringOverruns:   UInt64 { counterBuffer[2] }

    /// Diagnostic only: peak |sample| seen in the most recent callback.
    /// [0] = raw tap input (pre-gain), [1] = mixed output (post-gain/clip) —
    /// lets us tell "silent tap" apart from "audio lost downstream".
    private let peakBuffer: UnsafeMutableBufferPointer<Float>
    var lastInputPeak: Float { peakBuffer[0] }
    var lastMixPeak: Float { peakBuffer[1] }

    private let slotCount: Int

    /// One-shot diagnostic so we know the buffer layout at runtime.
    private var didLogPtr: UnsafeMutablePointer<UInt32>?

    init(
        outputDeviceUID: String,
        taps: [ProcessTap],
        callBoosted: [Bool],
        ringBuffer: FloatRingBuffer
    ) throws {
        precondition(taps.count <= 32, "Phase 3 supports up to 32 taps")
        precondition(callBoosted.count == taps.count, "callBoosted must be parallel to taps")
        self.slotCount = taps.count
        self.callBoosted = callBoosted
        self.ringBuffer = ringBuffer

        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, taps.count))
        buf.initialize(repeating: 1.0)
        self.gainBuffer = buf

        let lvlbuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, taps.count))
        lvlbuf.initialize(repeating: 0)
        self.levelBuffer = lvlbuf

        let smoothbuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, taps.count))
        smoothbuf.initialize(repeating: 1.0)
        self.smoothedGainBuffer = smoothbuf

        let envbuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, taps.count))
        envbuf.initialize(repeating: 0)
        self.agcEnvelopeBuffer = envbuf

        self.gainSlots = (0..<taps.count).map { i in
            GainSlot(
                pointer: buf.baseAddress!.advanced(by: i),
                levelPointer: lvlbuf.baseAddress!.advanced(by: i)
            )
        }

        let cbuf = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: 3)
        cbuf.initialize(repeating: 0)
        self.counterBuffer = cbuf

        let pbuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: 2)
        pbuf.initialize(repeating: 0)
        self.peakBuffer = pbuf

        // Build a private aggregate. We DO include the user's output device
        // as a sub-device — gives us a stable clock source matching the
        // playback device's sample rate.
        let aggregateUID = "com.fader.aggregate.\(UUID().uuidString)"
        var tapList: [[String: Any]] = []
        for tap in taps {
            if let uid = Self.tapUID(for: tap.tapID) {
                tapList.append([kAudioSubTapUIDKey: uid])
            }
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "Fader Capture",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: tapList
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard status == noErr, aggID != kAudioObjectUnknown else {
            buf.deallocate()
            lvlbuf.deallocate()
            smoothbuf.deallocate()
            envbuf.deallocate()
            cbuf.deallocate()
            pbuf.deallocate()
            throw AggregateError.creationFailed(status: status)
        }
        self.aggregateID = aggID
    }

    deinit {
        stop()
        if let pid = ioProcID {
            AudioDeviceDestroyIOProcID(aggregateID, pid)
        }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        gainBuffer.deallocate()
        levelBuffer.deallocate()
        smoothedGainBuffer.deallocate()
        agcEnvelopeBuffer.deallocate()
        counterBuffer.deallocate()
        peakBuffer.deallocate()
        didLogPtr?.deallocate()
    }

    func start() throws {
        let gainPtr = gainBuffer.baseAddress!
        let levelPtr = levelBuffer.baseAddress!
        let smoothedGainPtr = smoothedGainBuffer.baseAddress!
        let agcEnvelopePtr = agcEnvelopeBuffer.baseAddress!
        let boosted = callBoosted
        let counterPtr = counterBuffer.baseAddress!
        let peakPtr = peakBuffer.baseAddress!
        let count = slotCount
        let ring = ringBuffer

        let didLog = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        didLog.initialize(to: 0)
        self.didLogPtr = didLog

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateID,
            nil
        ) { _, inputData, _, outputData, _ in
            AggregateOutputDevice.captureCallback(
                input: inputData,
                output: outputData,
                gains: gainPtr,
                smoothedGains: smoothedGainPtr,
                levels: levelPtr,
                agcEnvelopes: agcEnvelopePtr,
                callBoosted: boosted,
                slotCount: count,
                ring: ring,
                counters: counterPtr,
                peaks: peakPtr,
                didLog: didLog
            )
        }
        guard status == noErr, let id = procID else {
            throw AggregateError.ioProcCreationFailed(status: status)
        }
        self.ioProcID = id

        let startStatus = AudioDeviceStart(aggregateID, id)
        guard startStatus == noErr else {
            throw AggregateError.startFailed(status: startStatus)
        }
        isRunning = true
    }

    /// Copies the current target gains into the smoothed-gain buffer.
    /// Called once, right before `start()`, so a freshly primed tap
    /// begins at its correct gain immediately instead of ramping in from
    /// the smoothed buffer's 1.0 default over the first ~7ms.
    func primeSmoothedGains() {
        for i in 0..<slotCount {
            smoothedGainBuffer[i] = gainBuffer[i]
        }
    }

    func stop() {
        guard isRunning, let id = ioProcID else { return }
        AudioDeviceStop(aggregateID, id)
        isRunning = false
    }

    // MARK: - Realtime callback — captures tap audio into the ring buffer.
    //
    // Strict realtime constraints: no allocation, no locks, no main-actor
    // state. Scratch space is stack-allocated as a fixed-size local buffer.

    /// Stereo float32 scratch space sized for one IOProc buffer.
    /// 2048 samples = 1024 stereo frames = ~21 ms at 48kHz — plenty of
    /// headroom for typical IOProc buffer sizes (256-1024 frames).
    private static let scratchSamples = 2048

    /// Max per-sample gain change — bounds any gain step (mute, unmute, a
    /// fast slider drag) to a ~7ms linear ramp instead of an instant
    /// jump, which is audible as a click. Assumes 48kHz like the rest of
    /// this pipeline (see ROADMAP.md's sample-rate-handling item — not
    /// dynamically queried yet anywhere in Phase 3).
    private static let maxGainStepPerSample: Float = 1.0 / (0.007 * 48000)

    // Call AGC tuning — see the doc comment where callGain is computed.
    // Untested against a real call (the harness blocks tools that touch a
    // live call's audio directly), so these are reasoned starting points,
    // not measured values — expect to retune target/max from real
    // feedback.
    private static let agcTargetPeak: Float = 0.6
    private static let agcAttack: Float = 0.5
    private static let agcRelease: Float = 0.05
    private static let agcFloor: Float = 0.003
    private static let agcMaxGain: Float = 16.0

    private static func captureCallback(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gains: UnsafeMutablePointer<Float>,
        smoothedGains: UnsafeMutablePointer<Float>,
        levels: UnsafeMutablePointer<Float>,
        agcEnvelopes: UnsafeMutablePointer<Float>,
        callBoosted: [Bool],
        slotCount: Int,
        ring: FloatRingBuffer,
        counters: UnsafeMutablePointer<UInt64>,
        peaks: UnsafeMutablePointer<Float>,
        didLog: UnsafeMutablePointer<UInt32>
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        if didLog.pointee == 0 {
            didLog.pointee = 1
            var msg = "[capture] inputBuffers=\(inList.count)"
            for (i, b) in inList.enumerated() {
                msg += " in[\(i)]: ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)"
            }
            msg += " | outputBuffers=\(outList.count)"
            for (i, b) in outList.enumerated() {
                msg += " out[\(i)]: ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)"
            }
            msg += "\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }

        // Always zero outputData — we don't drive audio from this device.
        for b in outList {
            if let m = b.mData {
                let f = m.assumingMemoryBound(to: Float.self)
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                f.update(repeating: 0, count: n)
            }
        }

        // Determine the mix length from the largest tap buffer.
        var mixSamples = 0
        let tapCount = min(inList.count, slotCount)
        for i in 0..<tapCount {
            let s = Int(inList[i].mDataByteSize) / MemoryLayout<Float>.size
            if s > mixSamples { mixSamples = s }
        }
        if mixSamples == 0 { return }
        mixSamples = min(mixSamples, scratchSamples)

        // Stack-allocate the mix scratch buffer (no heap alloc on realtime thread).
        withUnsafeTemporaryAllocation(of: Float.self, capacity: mixSamples) { mixBuf in
            // Zero.
            mixBuf.update(repeating: 0)

            var totalIn: UInt64 = 0
            var inputPeak: Float = 0

            for i in 0..<tapCount {
                let inB = inList[i]
                guard let mData = inB.mData else { levels[i] = 0; continue }
                let inFloats = mData.assumingMemoryBound(to: Float.self)
                let inSamples = Int(inB.mDataByteSize) / MemoryLayout<Float>.size
                totalIn &+= UInt64(inSamples)

                // This app's own peak (pre-gain) — real signal, published
                // for the UI's level meter. Single pass also feeds the
                // aggregate inputPeak diagnostic below.
                var tapPeak: Float = 0
                for f in 0..<inSamples {
                    let a = abs(inFloats[f])
                    if a > tapPeak { tapPeak = a }
                }
                levels[i] = tapPeak
                if tapPeak > inputPeak { inputPeak = tapPeak }

                // Call AGC: this tap's own slow peak-follower, used only to
                // derive an adaptive multiplier on top of the user's slider
                // gain. Fast attack (catches a loud moment quickly, so it
                // backs off before that moment clips) / slow release (so
                // gain doesn't audibly pump up and down between words in
                // normal speech, only over several seconds of sustained
                // level change). Never goes below 1.0 — this only adds
                // gain, it never makes the tap quieter than what the
                // slider already asked for.
                var callGain: Float = 1.0
                if callBoosted[i] {
                    let envPtr = agcEnvelopes.advanced(by: i)
                    var env = envPtr.pointee
                    if tapPeak > env {
                        env += (tapPeak - env) * agcAttack
                    } else {
                        env += (tapPeak - env) * agcRelease
                    }
                    envPtr.pointee = env
                    callGain = min(agcMaxGain, max(1.0, agcTargetPeak / max(env, agcFloor)))
                }

                // Ramp the applied gain toward the target sample-by-
                // sample rather than multiplying by a flat value for the
                // whole buffer — an instant step here (any mute, or a
                // fast slider move) is a waveform discontinuity, audible
                // as a click. Deliberately doesn't early-out at target
                // gain 0 (unlike the old flat-multiply path did): a
                // fresh mute still needs these samples to ramp down
                // through, not jump straight to silence.
                let target = gains.advanced(by: i).pointee * callGain
                var current = smoothedGains.advanced(by: i).pointee
                let n = min(inSamples, mixSamples)
                for f in 0..<n {
                    let diff = target - current
                    if abs(diff) <= maxGainStepPerSample {
                        current = target
                    } else {
                        current += diff > 0 ? maxGainStepPerSample : -maxGainStepPerSample
                    }
                    mixBuf[f] += inFloats[f] * current
                }
                smoothedGains.advanced(by: i).pointee = current
            }
            peaks[0] = inputPeak

            // Soft clip to prevent overshoot.
            var mixPeak: Float = 0
            for f in 0..<mixSamples {
                var s = mixBuf[f]
                if s > 1.0 { s = 1.0 }
                else if s < -1.0 { s = -1.0 }
                mixBuf[f] = s
                let a = abs(s)
                if a > mixPeak { mixPeak = a }
            }
            peaks[1] = mixPeak

            // Publish to ring buffer for the playback IOProc to consume.
            let written = ring.write(mixBuf.baseAddress!, count: mixSamples)

            counters[0] &+= totalIn
            counters[1] &+= UInt64(written)
            if written < mixSamples {
                counters[2] &+= UInt64(mixSamples - written)
            }
        }
    }

    // MARK: - Helpers

    /// Read the UID property of a tap object via `kAudioTapPropertyUID`.
    private static func tapUID(for tapID: AudioObjectID) -> String? {
        return CAObject.readString(tapID, .tapUID)
    }
}

enum AggregateError: Error, CustomStringConvertible {
    case creationFailed(status: OSStatus)
    case ioProcCreationFailed(status: OSStatus)
    case startFailed(status: OSStatus)
    case noDefaultOutputDevice

    var description: String {
        switch self {
        case let .creationFailed(s):       return "AudioHardwareCreateAggregateDevice failed: \(s)"
        case let .ioProcCreationFailed(s): return "AudioDeviceCreateIOProcIDWithBlock failed: \(s)"
        case let .startFailed(s):          return "AudioDeviceStart failed: \(s)"
        case .noDefaultOutputDevice:       return "Could not read default output device"
        }
    }
}
