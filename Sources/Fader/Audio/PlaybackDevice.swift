import Foundation
import CoreAudio
import AudioToolbox

/// **PLAYBACK half of Phase 3.**
///
/// Installs an IOProc on the user's actual default output device. On every
/// IOProc callback, reads up to `outputData.byteSize` samples from the
/// ring buffer and **adds** them into the device's output buffer. This way
/// our tapped-and-gain-adjusted audio mixes with whatever the system mixer
/// has already written for non-tapped apps.
///
/// Strict realtime constraints in the callback: no allocation, no locks,
/// no main-actor state.
final class PlaybackDevice {
    let deviceID: AudioObjectID
    private(set) var ioProcID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    private let ringBuffer: FloatRingBuffer

    /// Counters: [0]=samples-read-from-ring, [1]=underrun-samples-silenced.
    private let counterBuffer: UnsafeMutableBufferPointer<UInt64>

    var samplesFromRing: UInt64 { counterBuffer[0] }
    var underrunSamples: UInt64 { counterBuffer[1] }

    private var didLogPtr: UnsafeMutablePointer<UInt32>?

    init(deviceID: AudioObjectID, ringBuffer: FloatRingBuffer) {
        self.deviceID = deviceID
        self.ringBuffer = ringBuffer
        let cbuf = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: 2)
        cbuf.initialize(repeating: 0)
        self.counterBuffer = cbuf
    }

    deinit {
        stop()
        if let pid = ioProcID {
            AudioDeviceDestroyIOProcID(deviceID, pid)
        }
        counterBuffer.deallocate()
        didLogPtr?.deallocate()
    }

    func start() throws {
        let counterPtr = counterBuffer.baseAddress!
        let ring = ringBuffer

        let didLog = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        didLog.initialize(to: 0)
        self.didLogPtr = didLog

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            deviceID,
            nil
        ) { _, _, _, outputData, _ in
            PlaybackDevice.playbackCallback(
                output: outputData,
                ring: ring,
                counters: counterPtr,
                didLog: didLog
            )
        }
        guard status == noErr, let id = procID else {
            throw PlaybackError.ioProcCreationFailed(status: status)
        }
        self.ioProcID = id

        let startStatus = AudioDeviceStart(deviceID, id)
        guard startStatus == noErr else {
            throw PlaybackError.startFailed(status: startStatus)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning, let id = ioProcID else { return }
        AudioDeviceStop(deviceID, id)
        isRunning = false
    }

    // MARK: - Realtime callback

    /// Scratch space for ring buffer reads — sized for typical IOProc buffers.
    private static let scratchSamples = 4096

    /// Mix `value` into `*slot`, soft-clipped to [-1, 1].
    @inline(__always)
    private static func add(_ slot: inout Float, _ value: Float) {
        let s = slot + value
        slot = s > 1.0 ? 1.0 : (s < -1.0 ? -1.0 : s)
    }

    private static func playbackCallback(
        output: UnsafeMutablePointer<AudioBufferList>,
        ring: FloatRingBuffer,
        counters: UnsafeMutablePointer<UInt64>,
        didLog: UnsafeMutablePointer<UInt32>
    ) {
        let outList = UnsafeMutableAudioBufferListPointer(output)

        if didLog.pointee == 0 {
            didLog.pointee = 1
            var msg = "[playback] outputBuffers=\(outList.count)"
            for (i, b) in outList.enumerated() {
                msg += " out[\(i)]: ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)"
            }
            msg += "\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }

        // For the first output buffer (the physical output stream), mix in
        // ring buffer audio. Other buffers (if any — multi-stream devices)
        // are left alone.
        //
        // The ring buffer always carries stereo-interleaved frames (L, R, L,
        // R, ...) because AggregateOutputDevice mixes taps that way. The
        // *real* output device's channel count can differ (e.g. a Bluetooth
        // headset drops to mono HFP during a call), so we must down/up-mix
        // per frame here rather than copying raw floats 1:1 — copying raw
        // floats into a mono buffer interleaves L/R into consecutive mono
        // time-slots, which sounds scrambled/muffled.
        guard let outB = outList.first,
              let outM = outB.mData else { return }
        let outFloats = outM.assumingMemoryBound(to: Float.self)
        let channels = max(1, Int(outB.mNumberChannels))
        let outSamples = Int(outB.mDataByteSize) / MemoryLayout<Float>.size
        let outFrames = outSamples / channels
        let ringFrames = min(outFrames, scratchSamples / 2)
        let n = ringFrames * 2   // stereo floats to pull from the ring

        var totalRead: UInt64 = 0

        withUnsafeTemporaryAllocation(of: Float.self, capacity: max(1, n)) { scratch in
            scratch.update(repeating: 0)
            let readFloats = n > 0 ? ring.read(scratch.baseAddress!, count: n) : 0
            totalRead = UInt64(readFloats)
            let readFrames = readFloats / 2

            for frame in 0..<readFrames {
                let l = scratch[frame * 2]
                let r = scratch[frame * 2 + 1]
                let base = frame * channels
                if channels == 1 {
                    add(&outFloats[base], (l + r) * 0.5)
                } else {
                    add(&outFloats[base], l)
                    add(&outFloats[base + 1], r)
                    // Extra channels (>2) on the real device are left as-is.
                }
            }

            if readFrames < outFrames {
                counters[1] &+= UInt64(outFrames - readFrames)   // underrun
            }
        }
        counters[0] &+= totalRead
    }
}

enum PlaybackError: Error, CustomStringConvertible {
    case ioProcCreationFailed(status: OSStatus)
    case startFailed(status: OSStatus)

    var description: String {
        switch self {
        case let .ioProcCreationFailed(s): return "PlaybackDevice IOProc create failed: \(s)"
        case let .startFailed(s):          return "PlaybackDevice start failed: \(s)"
        }
    }
}
