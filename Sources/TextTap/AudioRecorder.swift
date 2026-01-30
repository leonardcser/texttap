import AVFoundation
import Foundation

class AudioRecorder {
    private static let sampleRate: Double = 16000  // Whisper expects 16kHz
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    var onAudioLevel: ((Float) -> Void)?
    var isRecording: Bool { audioEngine?.isRunning ?? false }

    func startRecording() throws -> URL {
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create temp file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "texttap_\(Int(Date().timeIntervalSince1970)).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)
        tempFileURL = fileURL

        // Create audio file with the desired format (16kHz mono for Whisper)
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!

        audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        // Create a converter if needed
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }

            // Calculate RMS level
            let level = self.calculateRMS(buffer: buffer)
            DispatchQueue.main.async {
                self.onAudioLevel?(level)
            }

            // Convert and write to file
            if let converter = converter {
                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
                    return
                }

                var error: NSError?
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

                if error == nil {
                    try? self.audioFile?.write(from: convertedBuffer)
                }
            } else {
                // Format matches, write directly
                try? self.audioFile?.write(from: buffer)
            }
        }

        try audioEngine.start()
        return fileURL
    }

    func stopRecording() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        audioFile = nil  // Close the file

        // Force file system sync to ensure all data is written to disk
        if let url = tempFileURL {
            let fd = open(url.path, O_RDONLY)
            if fd >= 0 {
                fsync(fd)
                close(fd)
            }
        }

        return tempFileURL
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
