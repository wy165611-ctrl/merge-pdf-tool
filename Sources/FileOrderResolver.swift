import Foundation

struct FileOrderResolver {
    struct Result {
        let orderedURLs: [URL]
        let unknownLines: [String]
        let duplicateLines: [String]
    }

    /// 将粘贴的“每行一个文件名”解析为文件顺序。
    /// 支持 Finder 粘贴出的完整路径、每行一个文件名，以及自然语言描述。
    static func resolve(urls: [URL], text: String) -> Result {
        let normalizedURLs = urls.map { $0.standardizedFileURL }
        let nonEmptyLines = text.components(separatedBy: .newlines)
            .map(cleanLine)
            .filter { !$0.isEmpty }

        // 对“每行一个文件名”的传统输入保持精确顺序。
        let explicit = explicitLineOrder(urls: normalizedURLs, lines: nonEmptyLines)
        if !explicit.orderedURLs.isEmpty && explicit.orderedURLs.count == nonEmptyLines.count {
            return Result(
                orderedURLs: explicit.orderedURLs,
                unknownLines: explicit.unknownLines,
                duplicateLines: explicit.duplicateLines
            )
        }

        // 没有完全匹配的逐行文件名时，按整段自然语言中的关键词位置排序。
        return naturalLanguageOrder(urls: normalizedURLs, text: text)
    }

    private static func explicitLineOrder(urls: [URL], lines: [String]) -> (orderedURLs: [URL], unknownLines: [String], duplicateLines: [String]) {
        let byPath = Dictionary(uniqueKeysWithValues: urls.map { ($0.path.lowercased(), $0) })
        let byName = Dictionary(grouping: urls) { $0.lastPathComponent.lowercased() }
        let byStem = Dictionary(grouping: urls) { $0.deletingPathExtension().lastPathComponent.lowercased() }
        let byNormalizedStem = Dictionary(grouping: urls) { normalize($0.deletingPathExtension().lastPathComponent) }

        var ordered: [URL] = []
        var usedPaths = Set<String>()
        var unknown: [String] = []
        var duplicates: [String] = []

        for line in lines {
            let candidates: [URL]
            if let exactPath = pathCandidate(from: line), let url = byPath[exactPath.lowercased()] {
                candidates = [url]
            } else if let matches = byName[line.lowercased()], !matches.isEmpty {
                candidates = matches
            } else if let matches = byStem[line.lowercased()], matches.count == 1 {
                candidates = matches
            } else if let matches = byNormalizedStem[normalize(line)], matches.count == 1 {
                candidates = matches
            } else {
                candidates = []
            }

            guard let url = candidates.first else {
                unknown.append(line)
                continue
            }
            let path = url.path.lowercased()
            if usedPaths.contains(path) {
                duplicates.append(line)
            } else {
                usedPaths.insert(path)
                ordered.append(url)
            }
        }
        return (ordered, unknown, duplicates)
    }

    private static func naturalLanguageOrder(urls: [URL], text: String) -> Result {
        let normalizedText = Array(normalize(text))
        var matches: [(url: URL, start: Int, length: Int, originalIndex: Int)] = []

        for (index, url) in urls.enumerated() {
            let fileName = Array(normalize(url.deletingPathExtension().lastPathComponent))
            guard !fileName.isEmpty,
                  let match = longestCommonSubstring(file: fileName, text: normalizedText) else { continue }

            let hasChinese = fileName.contains { character in
                character.unicodeScalars.contains { scalar in
                    (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                }
            }
            let baseMinimum = fileName.count <= 2 ? fileName.count : (hasChinese ? 2 : 3)
            // 防止“合并”“材料”等通用短词误命中较长文件名的一个后缀。
            let coverageMinimum = max(1, Int(ceil(Double(fileName.count) * 0.4)))
            let minimumLength = max(baseMinimum, coverageMinimum)
            guard match.length >= minimumLength else { continue }
            matches.append((url, match.start, match.length, index))
        }

        matches.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.length != $1.length { return $0.length > $1.length }
            return $0.originalIndex < $1.originalIndex
        }

        var ordered: [URL] = []
        var used = Set<String>()
        for match in matches where used.insert(match.url.path.lowercased()).inserted {
            ordered.append(match.url)
        }
        return Result(orderedURLs: ordered, unknownLines: [], duplicateLines: [])
    }

    private static func longestCommonSubstring(file: [Character], text: [Character]) -> (start: Int, length: Int)? {
        guard !file.isEmpty, !text.isEmpty else { return nil }
        var previous = Array(repeating: 0, count: file.count + 1)
        var bestStart = 0
        var bestLength = 0

        for textIndex in text.indices {
            var current = Array(repeating: 0, count: file.count + 1)
            for fileIndex in file.indices {
                guard file[fileIndex] == text[textIndex] else { continue }
                current[fileIndex + 1] = previous[fileIndex] + 1
                let length = current[fileIndex + 1]
                let start = textIndex - length + 1
                if length > bestLength || (length == bestLength && start < bestStart) {
                    bestLength = length
                    bestStart = start
                }
            }
            previous = current
        }
        return bestLength == 0 ? nil : (bestStart, bestLength)
    }

    private static func cleanLine(_ rawLine: String) -> String {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        line = line.replacingOccurrences(of: "\u{FEFF}", with: "")
        line = line.replacingOccurrences(of: "^[•●▪▸→]+\\s*", with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: "^\\d+\\s*[.、)、:]\\s*", with: "", options: .regularExpression)
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pathCandidate(from line: String) -> String? {
        if line.hasPrefix("/") {
            return URL(fileURLWithPath: line).standardizedFileURL.path
        }
        if line.hasPrefix("file://"), let url = URL(string: line) {
            return url.standardizedFileURL.path
        }
        return nil
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || (0x3400...0x4DBF).contains(scalar.value)
                    || (0x4E00...0x9FFF).contains(scalar.value)
            }
            .map(String.init)
            .joined()
    }
}
