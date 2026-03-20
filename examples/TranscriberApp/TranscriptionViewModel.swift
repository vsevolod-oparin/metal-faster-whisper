import Foundation
import SwiftUI

// MARK: - State Enums

enum ModelState: Equatable {
    case notLoaded
    case loading(progress: String)
    case ready
    case error(String)
}

enum TranscriptionState: Equatable {
    case idle
    case transcribing
    case done
    case error(String)
}

// MARK: - View Model

@MainActor
class TranscriptionViewModel: ObservableObject {

    // MARK: Published State

    @Published var modelState: ModelState = .notLoaded
    @Published var transcriptionState: TranscriptionState = .idle
    @Published var segments: [SegmentItem] = []
    @Published var selectedModel: String = "turbo"
    @Published var wordTimestamps: Bool = false
    @Published var vadFilter: Bool = false
    @Published var task: String = "transcribe"
    @Published var language: String = "auto"

    static let availableTasks = ["transcribe", "translate"]
    static let availableLanguages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("zh", "Chinese"),
        ("de", "German"),
        ("es", "Spanish"),
        ("ru", "Russian"),
        ("ko", "Korean"),
        ("fr", "French"),
        ("ja", "Japanese"),
        ("pt", "Portuguese"),
        ("tr", "Turkish"),
        ("pl", "Polish"),
        ("ca", "Catalan"),
        ("nl", "Dutch"),
        ("ar", "Arabic"),
        ("sv", "Swedish"),
        ("it", "Italian"),
        ("id", "Indonesian"),
        ("hi", "Hindi"),
        ("fi", "Finnish"),
        ("vi", "Vietnamese"),
        ("he", "Hebrew"),
        ("uk", "Ukrainian"),
        ("el", "Greek"),
        ("ro", "Romanian"),
        ("da", "Danish"),
        ("hu", "Hungarian"),
        ("th", "Thai"),
        ("no", "Norwegian"),
        ("cs", "Czech"),
    ]
    @Published var statusMessage: String = "Select a model to get started"
    @Published var droppedFileURL: URL?

    static let availableModels = ["tiny", "base", "small", "medium", "large-v3", "turbo"]

    // MARK: Private

    private var transcriber: MWTranscriber?

    // MARK: - Model Loading

    func loadModel() {
        guard modelState != .ready || transcriptionState != .transcribing else { return }

        modelState = .loading(progress: "Resolving model...")
        statusMessage = "Loading model \(selectedModel)..."
        segments = []
        transcriptionState = .idle
        transcriber = nil

        let modelAlias = selectedModel

        Task.detached { [weak self] in
            do {
                let manager = MWModelManager.shared()
                let path = try manager.resolveModel(
                    modelAlias,
                    progress: { bytesDownloaded, totalBytes, fileName in
                        let progressText: String
                        if totalBytes > 0 {
                            let pct = Double(bytesDownloaded) / Double(totalBytes) * 100
                            progressText = String(format: "Downloading %@... %.0f%%", fileName, pct)
                        } else {
                            let mb = Double(bytesDownloaded) / 1_048_576
                            progressText = String(format: "Downloading %@... %.1f MB", fileName, mb)
                        }
                        Task { @MainActor [weak self] in
                            self?.modelState = .loading(progress: progressText)
                            self?.statusMessage = progressText
                        }
                    }
                )

                await MainActor.run { [weak self] in
                    self?.modelState = .loading(progress: "Initializing transcriber...")
                    self?.statusMessage = "Initializing transcriber..."
                }

                let newTranscriber = try MWTranscriber(modelPath: path)

                await MainActor.run { [weak self] in
                    self?.transcriber = newTranscriber
                    self?.modelState = .ready
                    self?.statusMessage = "Model \(modelAlias) loaded and ready"
                }
            } catch {
                await MainActor.run { [weak self] in
                    let msg = error.localizedDescription
                    self?.modelState = .error(msg)
                    self?.statusMessage = "Failed to load model: \(msg)"
                }
            }
        }
    }

    // MARK: - Transcription

    func transcribe(url: URL) {
        guard let transcriber = transcriber else {
            statusMessage = "Load a model first"
            return
        }
        guard case .ready = modelState else {
            statusMessage = "Model is not ready"
            return
        }

        transcriptionState = .transcribing
        statusMessage = "Transcribing..."
        segments = []

        let options = MWTranscriptionOptions.defaults()
        options.wordTimestamps = wordTimestamps
        options.vadFilter = vadFilter

        let fileURL = url

        transcriber.transcribeURL(
            fileURL,
            language: language == "auto" ? nil : language,
            task: task,
            typedOptions: options,
            segmentHandler: { [weak self] segment, _ in
                let item = SegmentItem(
                    id: Int(segment.segmentId),
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    words: segment.words?.map { word in
                        WordItem(
                            start: word.start,
                            end: word.end,
                            word: word.word,
                            probability: word.probability
                        )
                    }
                )
                Task { @MainActor [weak self] in
                    self?.segments.append(item)
                }
            },
            completionHandler: { [weak self] allSegments, info, error in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let error = error {
                        self.transcriptionState = .error(error.localizedDescription)
                        self.statusMessage = "Transcription failed: \(error.localizedDescription)"
                        return
                    }

                    // Replace streamed segments with final result for consistency
                    if let allSegments = allSegments {
                        self.segments = allSegments.enumerated().map { index, seg in
                            SegmentItem(
                                id: index,
                                start: seg.start,
                                end: seg.end,
                                text: seg.text,
                                words: seg.words?.map { word in
                                    WordItem(
                                        start: word.start,
                                        end: word.end,
                                        word: word.word,
                                        probability: word.probability
                                    )
                                }
                            )
                        }
                    }

                    let langInfo: String
                    if let info = info {
                        langInfo = " | Language: \(info.language) (\(String(format: "%.0f%%", info.languageProbability * 100))) | Duration: \(String(format: "%.1fs", info.duration))"
                    } else {
                        langInfo = ""
                    }

                    self.transcriptionState = .done
                    self.statusMessage = "Transcription complete — \(self.segments.count) segments\(langInfo)"
                }
            }
        )
    }

    // MARK: - Export

    func exportTXT() -> String {
        ExportUtils.exportTXT(segments: segments)
    }

    func exportSRT() -> String {
        ExportUtils.exportSRT(segments: segments)
    }

    func exportVTT() -> String {
        ExportUtils.exportVTT(segments: segments)
    }

    // MARK: - Save to File

    func saveExport(content: String, fileExtension: String, title: String) {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcription.\(fileExtension)"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
