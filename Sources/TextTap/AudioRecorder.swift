import AVFoundation
import Foundation

class AudioRecorder {
    private static let sampleRate: Double = 16000  // Whisper expects 16kHz
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var recordingGeneration: Int = 0

    var onAudioLevel: ((Float) -> Void)?
    var isRecording: Bool { audioEngine?.isRunning ?? false }

    func startRecording() throws -> URL {
        print("[TextTap] AudioRecorder.startRecording() called")
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("[TextTap] Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")

        // Create temp file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "texttap_\(Int(Date().timeIntervalSince1970)).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)
        tempFileURL = fileURL
        print("[TextTap] Recording to: \(fileURL.path)")

        // Create audio file with the desired format (16kHz mono for Whisper)
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        audioFile = file

        // Create a converter if needed
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        var writeErrorCount = 0
        let generation = recordingGeneration

        // Install tap on input node
        // Captures `file` directly so writes never race with stopRecording setting audioFile = nil.
        // Captures `generation` to discard stale level callbacks after stop.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }

            // Calculate RMS level
            let level = self.calculateRMS(buffer: buffer)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.recordingGeneration == generation else { return }
                self.onAudioLevel?(level)
            }

            // Convert and write to captured file reference (not self.audioFile)
            if let converter = converter {
                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
                    print("[TextTap] Failed to create converted buffer")
                    return
                }

                var error: NSError?
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

                if let error = error {
                    writeErrorCount += 1
                    if writeErrorCount <= 5 {
                        print("[TextTap] Audio conversion error: \(error)")
                    }
                } else {
                    do {
                        try file.write(from: convertedBuffer)
                    } catch {
                        writeErrorCount += 1
                        if writeErrorCount <= 5 {
                            print("[TextTap] Audio write error: \(error)")
                        }
                    }
                }
            } else {
                // Format matches, write directly
                do {
                    try file.write(from: buffer)
                } catch {
                    writeErrorCount += 1
                    if writeErrorCount <= 5 {
                        print("[TextTap] Audio write error: \(error)")
                    }
                }
            }
        }

        try audioEngine.start()
        print("[TextTap] Audio engine started")
        return fileURL
    }

    func stopRecording() -> URL? {
        print("[TextTap] AudioRecorder.stopRecording() called")
        recordingGeneration += 1  // Invalidate pending level callbacks from this session

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        audioFile = nil  // Release our reference (tap closure may still hold the file briefly)

        let url = tempFileURL
        tempFileURL = nil  // Clear so cleanup() won't double-delete

        // Force file system sync to ensure all data is written to disk
        if let url = url {
            let fd = open(url.path, O_RDONLY)
            if fd >= 0 {
                fsync(fd)
                close(fd)
            }

            // Log file info
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let fileSize = attrs[.size] as? Int64 {
                print("[TextTap] Recording stopped. File: \(url.lastPathComponent), size: \(fileSize) bytes")
            }
        }

        return url
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    private func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }

        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0,
                                           to: Int(buffer.frameLength),
                                           by: buffer.stride).map { channelDataValue[$0] }

        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))
        return rms
    }
}
