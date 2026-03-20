import Foundation

enum ExportUtils {

    // MARK: - Plain Text

    static func exportTXT(segments: [SegmentItem]) -> String {
        segments.map { segment in
            let startStamp = formatTimestamp(segment.start, separator: ":")
            let endStamp = formatTimestamp(segment.end, separator: ":")
            return "[\(startStamp) --> \(endStamp)] \(segment.text.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n")
    }

    // MARK: - SRT

    static func exportSRT(segments: [SegmentItem]) -> String {
        segments.enumerated().map { index, segment in
            let num = index + 1
            let startStamp = formatSRTTimestamp(segment.start)
            let endStamp = formatSRTTimestamp(segment.end)
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            return "\(num)\n\(startStamp) --> \(endStamp)\n\(text)"
        }.joined(separator: "\n\n")
    }

    // MARK: - VTT

    static func exportVTT(segments: [SegmentItem]) -> String {
        var lines = ["WEBVTT", ""]
        for segment in segments {
            let startStamp = formatVTTTimestamp(segment.start)
            let endStamp = formatVTTTimestamp(segment.end)
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            lines.append("\(startStamp) --> \(endStamp)")
            lines.append(text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Timestamp Formatting

    /// Format as HH:MM:SS.mmm (or MM:SS.mm for display).
    private static func formatTimestamp(_ seconds: Float, separator: String) -> String {
        let totalSeconds = max(0, seconds)
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let secs = Int(totalSeconds) % 60
        let centiseconds = Int((totalSeconds - Float(Int(totalSeconds))) * 100)

        if hours > 0 {
            return String(format: "%02d%@%02d%@%02d.%02d", hours, separator, minutes, separator, secs, centiseconds)
        }
        return String(format: "%02d%@%02d.%02d", minutes, separator, secs, centiseconds)
    }

    /// SRT format: HH:MM:SS,mmm
    private static func formatSRTTimestamp(_ seconds: Float) -> String {
        let totalSeconds = max(0, seconds)
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let secs = Int(totalSeconds) % 60
        let milliseconds = Int((totalSeconds - Float(Int(totalSeconds))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, milliseconds)
    }

    /// VTT format: HH:MM:SS.mmm
    private static func formatVTTTimestamp(_ seconds: Float) -> String {
        let totalSeconds = max(0, seconds)
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let secs = Int(totalSeconds) % 60
        let milliseconds = Int((totalSeconds - Float(Int(totalSeconds))) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, milliseconds)
    }
}
