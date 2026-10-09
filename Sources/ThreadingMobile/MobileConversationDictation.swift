@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

/// One bounded recording, started only by a microphone tap. Audio engine setup and teardown
/// stay off the UI actor; buffers go straight to Speech and are never retained by the chat.
actor MobileConversationDictation {
    enum Event: Sendable { case listening, text(String), finished, unavailable }
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var deadline: Task<Void, Never>?
    private var generation = 0
    private var ownsAudioSession = false
    private var onUpdate: (@MainActor @Sendable (Event) -> Void)?

    func start(update: @escaping @MainActor @Sendable (Event) -> Void) async {
        stop()
        onUpdate = update
        let current = generation
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard current == generation else { return }
        guard speechAllowed, await AVAudioApplication.requestRecordPermission() else {
            if current == generation { await update(.unavailable) }
            return
        }
        guard current == generation else { return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            await update(.unavailable)
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)
            ownsAudioSession = true
            let engine = AVAudioEngine()
            self.engine = engine
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw RecordingError.noInput }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true || error != nil
                Task { await self?.receive(text, finished: finished, generation: current, update: update) }
            }
            engine.prepare()
            try engine.start()
            await update(.listening)
            guard current == generation else { return }
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled else { return }
                await self?.receive(nil, finished: true, generation: current, update: update)
            }
        } catch {
            stop()
            await update(.unavailable)
        }
    }

    func stop() {
        generation += 1
        deadline?.cancel()
        deadline = nil
        stopInput()
        request?.endAudio()
        request = nil
        recognition?.cancel()
        recognition = nil
        onUpdate = nil
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    /// Stop capturing immediately, but let Speech deliver its final words. The two-second
    /// deadline keeps a stalled recognizer from holding the editable draft indefinitely.
    func finish() {
        guard let update = onUpdate else { return }
        let current = generation
        stopInput()
        request?.endAudio()
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.receive(nil, finished: true, generation: current, update: update)
        }
    }

    private func stopInput() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }

    private func receive(
        _ text: String?, finished: Bool, generation current: Int,
        update: @escaping @MainActor @Sendable (Event) -> Void
    ) async {
        guard current == generation else { return }
        if let text { await update(.text(text)) }
        guard current == generation else { return }
        if finished {
            stop()
            await update(.finished)
        }
    }

    private enum RecordingError: Error { case noInput }
}
