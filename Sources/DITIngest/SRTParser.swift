import Foundation

struct SRTCue {
    let startTime: String // e.g. "00:04:12"
    let text: String
}

enum SRTParser {
    private static let timestampRegex = try! NSRegularExpression(pattern: "^(\\d{2}:\\d{2}:\\d{2})[,.]\\d{3}\\s*-->")

    static func parseCues(from srtContent: String) -> [SRTCue] {
        var cues: [SRTCue] = []
        let lines = srtContent.components(separatedBy: .newlines)
        
        var currentStartTime: String? = nil
        var currentTextLines: [String] = []
        
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let startTime = currentStartTime {
                    let text = currentTextLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        cues.append(SRTCue(startTime: startTime, text: text))
                    }
                }
                currentStartTime = nil
                currentTextLines = []
                continue
            }
            
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = timestampRegex.firstMatch(in: line, options: [], range: range) {
                if let timeRange = Range(match.range(at: 1), in: line) {
                    currentStartTime = String(line[timeRange])
                }
            } else if currentStartTime != nil {
                currentTextLines.append(line)
            }
        }
        
        if let startTime = currentStartTime {
            let text = currentTextLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                cues.append(SRTCue(startTime: startTime, text: text))
            }
        }
        
        return cues
    }

    static func parse(_ srtContent: String, maxCharsPerParagraph: Int = 1800) -> [String] {
        let cues = parseCues(from: srtContent)
        guard !cues.isEmpty else { return [] }
        
        var paragraphs: [String] = []
        var currentPrefix = ""
        var currentText = ""
        
        for cue in cues {
            let timePrefix = "[\(cue.startTime)]"
            if currentText.isEmpty {
                currentPrefix = timePrefix
                currentText = cue.text
            } else {
                let candidate = currentText + " " + cue.text
                let fullCandidateLength = currentPrefix.count + 1 + candidate.count
                if fullCandidateLength <= maxCharsPerParagraph {
                    currentText = candidate
                } else {
                    paragraphs.append("\(currentPrefix) \(currentText)")
                    currentPrefix = timePrefix
                    currentText = cue.text
                }
            }
        }
        
        if !currentText.isEmpty {
            paragraphs.append("\(currentPrefix) \(currentText)")
        }
        
        return paragraphs
    }
}
