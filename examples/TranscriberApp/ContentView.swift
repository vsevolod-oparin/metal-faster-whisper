import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main Content View

struct ContentView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            dropZone
            Divider()
            segmentList
            Divider()
            bottomBar
        }
        .frame(minWidth: 600, minHeight: 500)
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onChange(of: viewModel.modelState) { _, newValue in
            if case .error(let msg) = newValue {
                errorMessage = msg
                showErrorAlert = true
            }
        }
        .onChange(of: viewModel.transcriptionState) { _, newValue in
            if case .error(let msg) = newValue {
                errorMessage = msg
                showErrorAlert = true
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                Text("Model:")
                    .fontWeight(.medium)
                Picker("", selection: $viewModel.selectedModel) {
                    ForEach(TranscriptionViewModel.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .frame(width: 120)
                .labelsHidden()

                Button {
                    viewModel.loadModel()
                } label: {
                    if case .loading = viewModel.modelState {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .disabled(isModelLoading)
                .help("Load selected model")
            }

            Divider()
                .frame(height: 16)

            HStack(spacing: 8) {
                Text("Language:")
                    .fontWeight(.medium)
                Picker("", selection: $viewModel.language) {
                    ForEach(TranscriptionViewModel.availableLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .frame(width: 140)
                .labelsHidden()
            }

            Spacer()

            HStack(spacing: 6) {
                statusDot
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch viewModel.modelState {
        case .notLoaded: return .gray
        case .loading: return .orange
        case .ready:
            switch viewModel.transcriptionState {
            case .transcribing: return .orange
            case .done: return .green
            default: return .green
            }
        case .error: return .red
        }
    }

    private var isModelLoading: Bool {
        if case .loading = viewModel.modelState { return true }
        return false
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.05) : Color.clear)
                )

            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)

                Text("Drop audio file here")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("or click to browse")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                Button("Choose File...") {
                    chooseFile()
                }
                .buttonStyle(.bordered)
                .disabled(!isModelReady)
            }
        }
        .frame(height: 160)
        .padding(16)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private var isModelReady: Bool {
        if case .ready = viewModel.modelState { return true }
        return false
    }

    // MARK: - Segment List

    private var segmentList: some View {
        Group {
            if viewModel.segments.isEmpty {
                VStack {
                    Spacer()
                    if case .transcribing = viewModel.transcriptionState {
                        ProgressView("Transcribing...")
                            .padding()
                    } else {
                        Text("Transcription will appear here")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(viewModel.segments) { segment in
                                SegmentRow(segment: segment, showWords: viewModel.wordTimestamps)
                                    .id(segment.id)
                                Divider()
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: viewModel.segments.count) { _, _ in
                        if let last = viewModel.segments.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                Picker("Task:", selection: $viewModel.task) {
                    Text("Transcribe").tag("transcribe")
                    Text("Translate to English").tag("translate")
                }
                .pickerStyle(.menu)
                .frame(width: 220)

                Toggle(isOn: $viewModel.wordTimestamps) {
                    Label("Words", systemImage: "textformat.abc")
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: $viewModel.vadFilter) {
                    Label("VAD", systemImage: "waveform.badge.minus")
                }
                .toggleStyle(.checkbox)

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        let content = viewModel.exportTXT()
                        viewModel.saveExport(content: content, fileExtension: "txt", title: "Export as TXT")
                    } label: {
                        Label("TXT", systemImage: "doc.text")
                    }
                    .disabled(viewModel.segments.isEmpty)

                    Button {
                        let content = viewModel.exportSRT()
                        viewModel.saveExport(content: content, fileExtension: "srt", title: "Export as SRT")
                    } label: {
                        Label("SRT", systemImage: "captions.bubble")
                    }
                    .disabled(viewModel.segments.isEmpty)

                    Button {
                        let content = viewModel.exportVTT()
                        viewModel.saveExport(content: content, fileExtension: "vtt", title: "Export as VTT")
                    } label: {
                        Label("VTT", systemImage: "captions.bubble")
                    }
                    .disabled(viewModel.segments.isEmpty)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - File Handling

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an audio file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .audio,
            .mpeg4Audio,
            .wav,
            .mp3,
            UTType(filenameExtension: "flac") ?? .audio,
            UTType(filenameExtension: "ogg") ?? .audio,
        ]

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            viewModel.transcribe(url: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        guard isModelReady else {
            errorMessage = "Please load a model before transcribing."
            showErrorAlert = true
            return
        }

        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let urlString = String(data: data, encoding: .utf8),
                      let url = URL(string: urlString) else { return }

                let audioExtensions = ["wav", "mp3", "m4a", "flac", "ogg", "aac", "wma", "aiff", "mp4", "webm"]
                guard audioExtensions.contains(url.pathExtension.lowercased()) else {
                    Task { @MainActor in
                        errorMessage = "Unsupported file type: .\(url.pathExtension). Please drop an audio file."
                        showErrorAlert = true
                    }
                    return
                }

                Task { @MainActor in
                    viewModel.transcribe(url: url)
                }
            }
        }
    }
}

// MARK: - Segment Row

struct SegmentRow: View {
    let segment: SegmentItem
    let showWords: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatTime(segment.start))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                    .fixedSize()

                Text(segment.text.trimmingCharacters(in: .whitespaces))
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showWords, let words = segment.words, !words.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(words) { word in
                        WordBadge(word: word)
                    }
                }
                .padding(.leading, 78)
            }
        }
        .padding(.vertical, 2)
    }

    private func formatTime(_ seconds: Float) -> String {
        let totalSeconds = max(0, seconds)
        let minutes = Int(totalSeconds) / 60
        let secs = Int(totalSeconds) % 60
        let centiseconds = Int((totalSeconds - Float(Int(totalSeconds))) * 100)
        return String(format: "%02d:%02d.%02d", minutes, secs, centiseconds)
    }
}

// MARK: - Word Badge

struct WordBadge: View {
    let word: WordItem

    var body: some View {
        Text(word.word)
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(confidenceColor.opacity(0.15))
            .foregroundStyle(confidenceColor)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(String(format: "%.1f%% confidence | %.2fs - %.2fs", word.probability * 100, word.start, word.end))
    }

    private var confidenceColor: Color {
        if word.probability >= 0.9 { return .green }
        if word.probability >= 0.7 { return .orange }
        return .red
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let point = CGPoint(
                x: bounds.minX + result.positions[index].x,
                y: bounds.minY + result.positions[index].y
            )
            subview.place(at: point, proposal: .unspecified)
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX - spacing)
        }

        return (positions, CGSize(width: maxX, height: currentY + lineHeight))
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
