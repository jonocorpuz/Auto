import AVFoundation
import Foundation

/// A clip's timing plus its onset curve (`EnvelopeBuilder`), nil when it has no audio.
nonisolated struct ClipAudio: Sendable {
    let duration: Double
    let fps: Double?
    let envelope: [Float]?
}

/// Reads a media file's timing and sound for audio sync. Never writes anything.
nonisolated protocol ClipAudioReading: Sendable {
    func read(_ url: URL) async throws -> ClipAudio
}

nonisolated enum ClipAudioReaderError: Error, Equatable {
    case unreadable
}

/// AVFoundation: all audio tracks mixed to mono 8 kHz float, streamed into an envelope.
nonisolated struct AVClipAudioReader: ClipAudioReading {
    func read(_ url: URL) async throws -> ClipAudio {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ClipAudioReaderError.unreadable
        }
        var fps: Double?
        if let v = videoTracks.first, let rate = try? await v.load(.nominalFrameRate), rate > 0 { fps = Double(rate) }
        let seconds = duration.isNumeric ? duration.seconds : 0
        guard !audioTracks.isEmpty else { return ClipAudio(duration: seconds, fps: fps, envelope: nil) }
        let envelope = try Self.envelope(asset: asset, tracks: audioTracks)
        return ClipAudio(duration: seconds, fps: fps, envelope: envelope)
    }

    private static func envelope(asset: AVAsset, tracks: [AVAssetTrack]) throws -> [Float] {
        guard let reader = try? AVAssetReader(asset: asset) else { throw ClipAudioReaderError.unreadable }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: EnvelopeBuilder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ClipAudioReaderError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw ClipAudioReaderError.unreadable }

        var builder = EnvelopeBuilder()
        var scratch: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            let status = scratch.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            scratch.withUnsafeBufferPointer { builder.append(UnsafeBufferPointer(rebasing: $0[0..<count])) }
        }
        if reader.status == .failed { throw ClipAudioReaderError.unreadable }
        return builder.finish()
    }
}
