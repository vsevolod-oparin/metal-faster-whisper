# MetalWhisperApp

A SwiftUI macOS demo application for MetalWhisper -- native Whisper transcription on Apple Silicon via Metal.

## Setup Instructions

### Prerequisites

- macOS 14.0+ (Sonoma or later)
- Xcode 15.0+
- MetalWhisper framework built (run `cmake --build build/` from the project root)

### Project Setup

1. **Create the Xcode project:**
   Open Xcode -> File -> New -> Project -> macOS -> App (SwiftUI).
   Name it `MetalWhisperApp`. Choose Swift as the language and SwiftUI for the interface.

2. **Add source files:**
   Drag the following files from `app/MetalWhisperApp/` into the Xcode project navigator:
   - `MetalWhisperApp.swift` (replace the generated one)
   - `ContentView.swift` (replace the generated one)
   - `TranscriptionViewModel.swift`
   - `SegmentItem.swift`
   - `ExportUtils.swift`
   - `MetalWhisper-Bridging-Header.h`

3. **Configure the bridging header:**
   In Build Settings, search for "Objective-C Bridging Header" and set it to:
   ```
   $(SRCROOT)/MetalWhisper-Bridging-Header.h
   ```
   (Adjust the path if you placed the header in a subdirectory.)

4. **Add Header Search Paths:**
   In Build Settings -> Header Search Paths, add:
   ```
   $(PROJECT_DIR)/../../src
   ```
   This lets the bridging header find `MetalWhisper.h` and all framework headers.

5. **Add Library Search Paths:**
   In Build Settings -> Library Search Paths, add:
   ```
   $(PROJECT_DIR)/../../build
   ```

6. **Link against the framework libraries:**
   In Build Phases -> Link Binary With Libraries, add:
   - `libMetalWhisper.dylib`
   - `libctranslate2.dylib`
   - `libonnxruntime.dylib`

   You may need to click "Add Other..." and navigate to the `build/` directory.

7. **Set the runtime library path (rpath):**
   In Build Settings -> Runpath Search Paths, add:
   ```
   @executable_path/../Frameworks
   ```
   For development, you may also want to add the absolute path to `build/`.

8. **Copy dylibs into the app bundle (optional but recommended):**
   Add a "Copy Files" build phase targeting "Frameworks" and include the three `.dylib` files.

9. **Build and run.**

### Usage

1. Select a model size from the dropdown (turbo is recommended for speed).
2. Click the download/load button to initialize the model.
3. Drop an audio file onto the drop zone, or click "Choose File..." to browse.
4. Watch transcription segments appear in real time.
5. Use the export buttons to save as TXT, SRT, or VTT.

### Options

- **Word timestamps**: When enabled, the transcriber produces word-level timing. Words appear as colored badges below each segment, with color indicating confidence (green = high, orange = medium, red = low).
- **VAD filter**: Applies Silero voice activity detection to skip non-speech regions, which can improve accuracy and speed on files with long silences.

### Supported Audio Formats

WAV, MP3, M4A, FLAC, OGG, AAC, AIFF, MP4, WebM -- any format supported by the MetalWhisper audio decoder.
