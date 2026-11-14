import Foundation

public struct SecretScanConfiguration: Equatable {
    public static let defaultExcludedDirectories: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", "Pods", "Carthage", ".build", "DerivedData", "build", "dist",
        ".venv", "venv", "__pycache__", ".gradle", ".idea", "target", ".next", ".terraform"
    ]
    /// Lock files are full of integrity hashes, so the high-entropy rule skips them.
    public static let lockFiles: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "podfile.lock", "cargo.lock", "go.sum", "gemfile.lock",
        "poetry.lock", "composer.lock", "package.resolved", "pipfile.lock"
    ]

    public var maxFiles = 5_000
    public var maxFileBytes = 1_048_576
    public var maxTotalBytes = 64 * 1_048_576
    public var maxArchiveBytes = 25 * 1_048_576
    public var maxArchiveEntries = 10_000
    public var timeout: TimeInterval = 180
    /// User exclusions as glob patterns, e.g. `*.min.js`, `docs/`, `tests/fixtures/**`.
    public var exclusions: [String] = []
    public var useDefaultExclusions = true
    /// Fingerprints of findings the user marked as false positives.
    public var suppressedFingerprints: Set<String> = []
    /// Per-installation key for fingerprints, so a fingerprint cannot be used to guess a weak secret.
    public var fingerprintKey: [UInt8]

    public init(fingerprintKey: [UInt8]) {
        self.fingerprintKey = fingerprintKey
    }

    public var limits: AssessmentLimits {
        AssessmentLimits(maxFiles: maxFiles, maxFileBytes: maxFileBytes, maxTotalBytes: maxTotalBytes, overallTimeout: timeout)
    }
}

/// Minimal glob matching for exclusions. `*` matches within a path segment, `**` across segments, `?` one
/// character. A pattern without `/` matches any path segment; a trailing `/` matches a directory and its contents.
public struct GlobPattern: Equatable {
    public let pattern: String
    private let regex: NSRegularExpression

    public static func == (lhs: GlobPattern, rhs: GlobPattern) -> Bool { lhs.pattern == rhs.pattern }

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
        let directory = text.hasSuffix("/")
        if directory { text.removeLast() }
        while text.hasPrefix("./") { text.removeFirst(2) }
        if text.hasPrefix("/") { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        var body = ""
        var characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                if index + 1 < characters.count && characters[index + 1] == "*" {
                    body += ".*"
                    index += 1
                } else {
                    body += "[^/]*"
                }
            } else if character == "?" {
                body += "[^/]"
            } else {
                body += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        characters = []
        let anchoredStart = text.contains("/") ? "^" : "(?:^|/)"
        let end = directory ? "(?:/.*)?$" : "(?:/.*)?$"
        guard let regex = try? NSRegularExpression(pattern: anchoredStart + body + end) else { return nil }
        self.pattern = raw
        self.regex = regex
    }

    public func matches(_ relativePath: String) -> Bool {
        regex.firstMatch(in: relativePath, range: NSRange(relativePath.startIndex..., in: relativePath)) != nil
    }
}

/// One candidate secret, with everything needed to report it except the value, which is only used for
/// redaction and the fingerprint.
public struct SecretCandidate: Equatable {
    public let ruleID: String
    public let line: Int
    public let column: Int
    public let value: String
    public let severity: FindingSeverity
    public let confidence: FindingConfidence
    public let note: String?
    /// The source line with every candidate on it redacted.
    public let redactedLine: String
    public let suppressedInline: Bool
}

public final class SecretScanner {
    public let configuration: SecretScanConfiguration
    private let exclusionPatterns: [GlobPattern]

    public static let limitations = [
        "Pattern detection cannot prove whether a credential is active. Sentinel never tests discovered credentials against any service.",
        "Only the files as they are now are scanned; earlier versions in Git history or other branches are not.",
        "Binary files, encrypted or nested archive entries, symbolic links and files over the size limit are not examined.",
        "High-entropy matches have low confidence; many are harmless identifiers or hashes.",
        "Detection relies on known formats and naming. A secret in an unusual format or under an unrelated name can be missed."
    ]

    public init(configuration: SecretScanConfiguration) {
        self.configuration = configuration
        self.exclusionPatterns = configuration.exclusions.compactMap(GlobPattern.init)
    }

    // MARK: Text analysis

    private static let maxLineLength = 10_000
    private static let inlineAllowMarkers = ["sentinel:allow", "gitleaks:allow"]
    private static let base64Body = try! NSRegularExpression(pattern: "^[A-Za-z0-9+/=]{16,}$")

    /// Finds candidate secrets in text. `path` is used only to recognise lock files.
    public func candidates(in text: String, path: String) -> [SecretCandidate] {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let fileName = (path as NSString).lastPathComponent.lowercased()
        let isLockFile = SecretScanConfiguration.lockFiles.contains(fileName)
        var results: [SecretCandidate] = []

        for (index, fullLine) in lines.enumerated() {
            let line = fullLine.count > SecretScanner.maxLineLength ? String(fullLine.prefix(SecretScanner.maxLineLength)) : fullLine
            if line.isEmpty { continue }
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)
            var found: [(rule: SecretRule, range: NSRange, severity: FindingSeverity, confidence: FindingConfidence, note: String?)] = []

            func overlaps(_ range: NSRange) -> Bool { found.contains { NSIntersectionRange($0.range, range).length > 0 } }

            // Private keys: the header line marks the block; the body is never read into a finding.
            if let header = SecretRules.privateKeyHeader.firstMatch(in: line, range: whole) {
                let kind = ns.substring(with: header.range(at: 1))
                let next = lines.dropFirst(index + 1).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                let trimmedNext = next.trimmingCharacters(in: .whitespaces)
                let hasBody = SecretScanner.base64Body.firstMatch(in: trimmedNext, range: NSRange(location: 0, length: (trimmedNext as NSString).length)) != nil
                    || trimmedNext.hasPrefix("Proc-Type:")
                let encrypted = kind.hasPrefix("ENCRYPTED") || trimmedNext.hasPrefix("Proc-Type:")
                found.append((SecretRules.privateKey, header.range, encrypted ? .medium : .high, hasBody ? .high : .low,
                              hasBody ? (encrypted ? "The key is encrypted with a passphrase, which lowers but does not remove the risk." : nil)
                                      : "No key body follows the header; this may be documentation."))
            }

            for rule in SecretRules.specific {
                for match in rule.pattern.matches(in: line, range: whole) {
                    let range = match.range(at: rule.group)
                    guard range.location != NSNotFound, !overlaps(range) else { continue }
                    let value = ns.substring(with: range)
                    if rule.id == "url-credentials" && SecretRules.isPlaceholder(value) { continue }
                    found.append((rule, range, rule.severity, rule.confidence, nil))
                }
            }

            for rule in SecretRules.assignments {
                for match in rule.pattern.matches(in: line, range: whole) {
                    let range = match.range(at: rule.group)
                    guard range.location != NSNotFound, !overlaps(range) else { continue }
                    let value = ns.substring(with: range)
                    guard !SecretRules.isPlaceholder(value) else { continue }
                    let strong = value.count >= 10 && SecretRules.entropy(value) >= 3.0
                    found.append((rule, range, rule.severity, strong ? .medium : .low, nil))
                }
            }

            if !isLockFile,
               SecretRules.entropyContext.firstMatch(in: line, range: whole) != nil,
               SecretRules.digestContext.firstMatch(in: line, range: whole) == nil {
                for match in SecretRules.entropyCandidates.matches(in: line, range: whole) {
                    let range = match.range(at: 1)
                    guard !overlaps(range) else { continue }
                    let value = ns.substring(with: range)
                    let isHex = value.allSatisfy { $0.isHexDigit }
                    let entropy = SecretRules.entropy(value)
                    let mixed = value.contains(where: { $0.isUppercase }) && value.contains(where: { $0.isLowercase }) && value.contains(where: { $0.isNumber })
                    let random = isHex ? (value.count >= 32 && entropy >= 3.5) : (mixed && entropy >= 4.2)
                    guard random, !SecretRules.isPlaceholder(value) else { continue }
                    found.append((SecretRules.highEntropy, range, .low, .low, String(format: "Entropy %.1f bits per character.", entropy)))
                }
            }

            guard !found.isEmpty else { continue }
            var redacted = line
            for item in found.sorted(by: { $0.range.location > $1.range.location }) {
                guard let swiftRange = Range(item.range, in: redacted) else { continue }
                let replacement = item.rule.id == SecretRules.privateKey.id
                    ? String(redacted[swiftRange])
                    : SecretRules.redact(String(redacted[swiftRange]), visiblePrefix: item.rule.visiblePrefix)
                redacted.replaceSubrange(swiftRange, with: replacement)
            }
            redacted = Redactor.standard.text(redacted).trimmingCharacters(in: .whitespaces)
            if redacted.count > 200 { redacted = String(redacted.prefix(200)) + "…" }
            let allowed = SecretScanner.inlineAllowMarkers.contains { line.contains($0) }
            for item in found {
                results.append(SecretCandidate(ruleID: item.rule.id, line: index + 1, column: item.range.location + 1,
                                               value: ns.substring(with: item.range), severity: item.severity,
                                               confidence: item.confidence, note: item.note, redactedLine: redacted,
                                               suppressedInline: allowed))
            }
        }
        return results
    }

    /// Keyed fingerprint of a finding: stable across line moves, unique per file and value.
    public func fingerprint(ruleID: String, path: String, value: String) -> String {
        let message = Array("\(ruleID)\u{0}\(path)\u{0}\(value)".utf8)
        return HMACSHA256.authenticationCode(key: configuration.fingerprintKey, message: message)
            .prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Scanning

    private struct WorkItem {
        let url: URL
        let display: String
        let archive: ArchiveKind?
    }

    private struct Tally {
        var textFiles = 0
        var binary = 0
        var oversized: [String] = []
        var symlinks: [String] = []
        var excluded = 0
        var unreadable: [String] = []
        var archiveSkips: [String] = []
        var unsafeEntries: [(path: String, reason: String)] = []
        var archivesRead = 0
        var bytesRead = 0
        var budgetExhausted = false
        var suppressed = 0
    }

    /// Scans the selected folders, files and archives. Blocking; call it off the main thread.
    public func scan(_ sources: [URL], control: AssessmentControl, now: () -> Date = Date.init,
                     progress: (AssessmentProgress) -> Void = { _ in }) -> SecurityAssessmentRecord {
        let fileManager = FileManager.default
        let scope = sources.map { url -> ScopeItem in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let kind: ScopeItem.Kind = isDirectory ? .folder : (ArchiveKind.detect(name: url.lastPathComponent, header: []) != nil ? .archive : .file)
            return ScopeItem(kind: kind, value: url.lastPathComponent)
        }
        var record = SecurityAssessmentRecord(module: .secretScanner, scope: scope, location: .thisDevice,
                                              permissions: ["Read the \(sources.count) selected item(s) on this device",
                                                            "No network access", "Nothing uploaded"],
                                              startedAt: now(), limits: configuration.limits,
                                              limitations: SecretScanner.limitations)
        if !configuration.exclusions.isEmpty {
            record.scope.append(contentsOf: configuration.exclusions.map { ScopeItem(kind: .file, value: "Excluded: \($0)") })
        }
        var tally = Tally()
        var findings: [SecurityFinding] = []
        var stop: AssessmentControl.Stop?

        // 1. Plan: enumerate files without following symbolic links.
        var work: [WorkItem] = []
        var overflow = 0
        do {
            for source in sources {
                try control.check()
                let rootName = source.lastPathComponent
                let values = try? source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                if values?.isSymbolicLink == true {
                    tally.symlinks.append(rootName)
                    continue
                }
                if values?.isDirectory == true {
                    try enumerate(folder: source, rootName: rootName, fileManager: fileManager, control: control,
                                  work: &work, overflow: &overflow, tally: &tally)
                } else if values?.isRegularFile == true {
                    if work.count < configuration.maxFiles {
                        let header = (try? FileHandle(forReadingFrom: source)).map { handle -> [UInt8] in
                            defer { try? handle.close() }
                            return [UInt8](handle.readData(ofLength: 4))
                        } ?? []
                        work.append(WorkItem(url: source, display: rootName, archive: ArchiveKind.detect(name: rootName, header: header)))
                    } else {
                        overflow += 1
                    }
                } else {
                    tally.unreadable.append(rootName)
                }
            }
        } catch let error as AssessmentControl.Stop {
            stop = error
        } catch {
            record.errors.append("Listing files failed: \(error.localizedDescription)")
        }
        if overflow > 0 {
            record.notTested.append("\(overflow) file(s) beyond the \(configuration.maxFiles)-file limit were not scanned")
        }
        record.workTotal = work.count
        progress(AssessmentProgress(completed: 0, total: work.count, current: "Listed \(work.count) file(s)"))

        // 2. Scan.
        if stop == nil {
            do {
                for item in work {
                    progress(AssessmentProgress(completed: record.workCompleted, total: record.workTotal, current: item.display))
                    try control.check()
                    if tally.budgetExhausted {
                        record.notTested.append("\(item.display): the \(ByteFormatting.string(configuration.maxTotalBytes)) total read limit was reached")
                        record.workCompleted += 1
                        continue
                    }
                    if let kind = item.archive {
                        try scanArchive(item, kind: kind, control: control, record: &record, tally: &tally, findings: &findings)
                    } else {
                        scanFile(item, record: &record, tally: &tally, findings: &findings)
                    }
                    record.workCompleted += 1
                }
            } catch let error as AssessmentControl.Stop {
                stop = error
            } catch {
                record.errors.append("Scanning stopped: \(error.localizedDescription)")
            }
        }

        // 3. Summarise what was not examined.
        if tally.binary > 0 { record.notTested.append("\(tally.binary) binary file(s) were skipped") }
        if !tally.oversized.isEmpty {
            record.notTested.append("\(tally.oversized.count) file(s) larger than \(ByteFormatting.string(configuration.maxFileBytes)) were skipped: " + summarize(tally.oversized))
        }
        if !tally.symlinks.isEmpty {
            record.notTested.append("\(tally.symlinks.count) symbolic link(s) were not followed: " + summarize(tally.symlinks))
        }
        if tally.excluded > 0 { record.notTested.append("\(tally.excluded) item(s) matched an exclusion") }
        if !tally.unreadable.isEmpty {
            record.notTested.append("\(tally.unreadable.count) item(s) could not be read: " + summarize(tally.unreadable))
        }
        if !tally.archiveSkips.isEmpty {
            record.notTested.append("\(tally.archiveSkips.count) archive entr(ies) were not examined: " + summarize(tally.archiveSkips))
        }
        if let stop = stop {
            let remaining = record.workTotal - record.workCompleted
            if remaining > 0 { record.notTested.append("\(remaining) file(s) were not reached before the scan stopped") }
        }

        // 4. Checks and status.
        let complete = stop == nil && !tally.budgetExhausted
        for category in SecretCategory.allCases {
            let hits = findings.filter { SecretRules.rule(id: $0.checkID)?.category == category }.count
            let outcome: CheckOutcome
            let detail: String
            if hits > 0 {
                outcome = .finding
                detail = "\(hits) match\(hits == 1 ? "" : "es")"
            } else if tally.textFiles == 0 {
                outcome = .inconclusive
                detail = "No readable text files were scanned."
            } else if !complete {
                outcome = .inconclusive
                detail = "No matches in the \(tally.textFiles) file(s) scanned, but the scan did not finish."
            } else {
                outcome = .passed
                detail = "No matches in \(tally.textFiles) text file(s)."
            }
            record.checks.append(CheckResult(id: category.rawValue, title: category.checkTitle, outcome: outcome, detail: detail))
        }
        if tally.archivesRead > 0 || !tally.unsafeEntries.isEmpty {
            if tally.unsafeEntries.isEmpty {
                record.checks.append(CheckResult(id: "archive-safety", title: "Archive entry paths", outcome: .passed,
                                                 detail: "\(tally.archivesRead) archive(s) had no entries that escape their folder."))
            } else {
                record.checks.append(CheckResult(id: "archive-safety", title: "Archive entry paths", outcome: .finding,
                                                 detail: "\(tally.unsafeEntries.count) unsafe entry name(s)."))
                for (offset, entry) in tally.unsafeEntries.prefix(50).enumerated() {
                    findings.append(SecurityFinding(
                        id: "archive-unsafe-path:\(offset)", checkID: "archive-unsafe-path", title: "Archive entry escapes its folder",
                        severity: .medium, confidence: .high, basis: .verified, location: entry.path,
                        evidence: ["Entry name \(entry.reason)."],
                        explanation: "Extracting this archive with a tool that does not check names could write outside the target folder (\"zip slip\"). Sentinel did not extract it.",
                        remediation: "Do not extract this archive with untrusted tools; rebuild it with relative paths only."))
                }
            }
        }
        record.findings = findings
        record.suppressedCount = tally.suppressed
        record.endedAt = now()
        if let stop = stop {
            record.status = AssessmentRunStatus(stop: stop)
        } else if tally.textFiles == 0 && work.isEmpty && !tally.unreadable.isEmpty {
            record.status = .failedToExecute
        } else {
            record.status = .completed
        }
        progress(AssessmentProgress(completed: record.workCompleted, total: record.workTotal, current: record.status.label))
        return record
    }

    private func summarize(_ items: [String]) -> String {
        let shown = items.prefix(5).joined(separator: ", ")
        return items.count > 5 ? shown + " and \(items.count - 5) more" : shown
    }

    private func isExcluded(relativePath: String, name: String, isDirectory: Bool) -> Bool {
        if isDirectory && configuration.useDefaultExclusions && SecretScanConfiguration.defaultExcludedDirectories.contains(name) { return true }
        return exclusionPatterns.contains { $0.matches(relativePath) }
    }

    private func enumerate(folder: URL, rootName: String, fileManager: FileManager, control: AssessmentControl,
                           work: inout [WorkItem], overflow: inout Int, tally: inout Tally) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        var unreadable: [String] = []
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys, options: [],
                                                      errorHandler: { url, _ in unreadable.append(url.lastPathComponent); return true }) else {
            tally.unreadable.append(rootName)
            return
        }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited % 200 == 0 { try control.check() }
            // Resolve only the parent, never the item itself, so a symlink's own location is used.
            let itemPath = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                .appendingPathComponent(url.lastPathComponent).path
            let relative = itemPath.hasPrefix(base + "/") ? String(itemPath.dropFirst(base.count + 1)) : url.lastPathComponent
            let display = rootName + "/" + relative
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                tally.symlinks.append(display)
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true {
                if isExcluded(relativePath: relative, name: url.lastPathComponent, isDirectory: true) {
                    tally.excluded += 1
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if isExcluded(relativePath: relative, name: url.lastPathComponent, isDirectory: false) {
                tally.excluded += 1
                continue
            }
            guard work.count < configuration.maxFiles else {
                overflow += 1
                continue
            }
            work.append(WorkItem(url: url, display: display, archive: ArchiveKind.detect(name: url.lastPathComponent, header: [])))
        }
        tally.unreadable.append(contentsOf: unreadable)
    }

    private func readFile(_ item: WorkItem, limit: Int, tally: inout Tally) -> [UInt8]? {
        let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > limit {
            tally.oversized.append(item.display)
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: item.url) else {
            tally.unreadable.append(item.display)
            return nil
        }
        defer { try? handle.close() }
        // Read at most limit + 1 bytes, in case the file grew after it was listed.
        let data = handle.readData(ofLength: limit + 1)
        if data.count > limit {
            tally.oversized.append(item.display)
            return nil
        }
        return [UInt8](data)
    }

    private func scanFile(_ item: WorkItem, record: inout SecurityAssessmentRecord, tally: inout Tally, findings: inout [SecurityFinding]) {
        let remaining = configuration.maxTotalBytes - tally.bytesRead
        guard remaining > 0 else {
            tally.budgetExhausted = true
            record.notTested.append("\(item.display): the total read limit was reached")
            return
        }
        let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size <= configuration.maxFileBytes && size > remaining {
            tally.budgetExhausted = true
            record.notTested.append("\(item.display): the \(ByteFormatting.string(configuration.maxTotalBytes)) total read limit was reached")
            return
        }
        guard let bytes = readFile(item, limit: min(configuration.maxFileBytes, remaining), tally: &tally) else { return }
        tally.bytesRead += bytes.count
        scanBytes(bytes, display: item.display, tally: &tally, findings: &findings)
    }

    private func scanArchive(_ item: WorkItem, kind: ArchiveKind, control: AssessmentControl, record: inout SecurityAssessmentRecord,
                             tally: inout Tally, findings: inout [SecurityFinding]) throws {
        guard let bytes = readFile(item, limit: configuration.maxArchiveBytes, tally: &tally) else { return }
        let limits = ArchiveLimits(maxEntries: configuration.maxArchiveEntries, maxEntryBytes: configuration.maxFileBytes,
                                   maxTotalBytes: max(0, configuration.maxTotalBytes - tally.bytesRead))
        do {
            var localTally = tally
            var localFindings = findings
            try ArchiveReader.read(bytes, kind: kind, archiveName: item.url.lastPathComponent, limits: limits, control: control) { entry in
                switch entry {
                case .file(let path, let data):
                    localTally.bytesRead += data.count
                    record.workTotal += 1
                    record.workCompleted += 1
                    scanBytes(data, display: "\(item.display)!/\(path)", tally: &localTally, findings: &localFindings)
                case .skipped(let path, let reason):
                    localTally.archiveSkips.append("\(item.display)!/\(path) (\(reason))")
                case .unsafePath(let path, let reason):
                    localTally.unsafeEntries.append(("\(item.display)!/\(path)", reason))
                }
            }
            tally = localTally
            findings = localFindings
            tally.archivesRead += 1
        } catch let stop as AssessmentControl.Stop {
            throw stop
        } catch let error as ArchiveError {
            record.errors.append("\(item.display): \(error.description)")
            record.notTested.append("\(item.display): archive could not be read")
        } catch {
            record.errors.append("\(item.display): \(error.localizedDescription)")
            record.notTested.append("\(item.display): archive could not be read")
        }
    }

    static func isBinary(_ bytes: [UInt8]) -> Bool {
        let sample = bytes.prefix(8_000)
        if sample.contains(0) { return true }
        let text = String(decoding: sample, as: UTF8.self)
        let replacements = text.unicodeScalars.filter { $0 == "\u{FFFD}" }.count
        return sample.count > 0 && Double(replacements) / Double(max(1, text.unicodeScalars.count)) > 0.1
    }

    private func scanBytes(_ bytes: [UInt8], display: String, tally: inout Tally, findings: inout [SecurityFinding]) {
        if SecretScanner.isBinary(bytes) {
            tally.binary += 1
            return
        }
        tally.textFiles += 1
        let text = String(decoding: bytes, as: UTF8.self)
        for candidate in candidates(in: text, path: display) {
            let fingerprint = self.fingerprint(ruleID: candidate.ruleID, path: display, value: candidate.value)
            if candidate.suppressedInline || configuration.suppressedFingerprints.contains(fingerprint) {
                tally.suppressed += 1
                continue
            }
            guard let rule = SecretRules.rule(id: candidate.ruleID) else { continue }
            var evidence = [candidate.redactedLine]
            if rule.id != SecretRules.privateKey.id {
                evidence.append("Value: \(SecretRules.redact(candidate.value, visiblePrefix: rule.visiblePrefix))")
            } else {
                evidence.append("The key body is not shown.")
            }
            if let note = candidate.note { evidence.append(note) }
            findings.append(SecurityFinding(
                id: "\(rule.id):\(display):\(candidate.line):\(candidate.column)", checkID: rule.id, title: rule.title,
                severity: candidate.severity, confidence: candidate.confidence, basis: .observation,
                location: "\(display):\(candidate.line)", evidence: evidence,
                explanation: rule.explanation + " A pattern match cannot show whether the credential is active; Sentinel does not test it.",
                remediation: rule.remediation, fingerprint: fingerprint))
        }
    }
}
