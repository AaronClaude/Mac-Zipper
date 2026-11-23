import Foundation

enum ArchiveEngineError: LocalizedError, Sendable {
    case unsupportedFormat(String)
    case fileNotFound(URL)
    case passwordRequired(String?)
    case wrongPassword
    case extractionFailed(String, suggestUnar: Bool)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported archive format: .\(ext)"
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .passwordRequired(let msg):
            return msg ?? "This archive is password protected."
        case .wrongPassword:
            return "Incorrect password. Please try again."
        case .extractionFailed(let message, _):
            return message
        case .cancelled:
            return "Extraction cancelled."
        }
    }
}

struct CommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

final class ArchiveEngine: Sendable {
    static let shared = ArchiveEngine()

    private let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]

    func findExecutable(_ name: String) -> URL? {
        let fm = FileManager.default
        if let bundleBin = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
           fm.isExecutableFile(atPath: bundleBin.path) {
            return bundleBin
        }
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func backendStatus() -> BackendStatus {
        let rarBackend: RarBackend
        if findExecutable("unar") != nil {
            rarBackend = .unar
        } else if findExecutable("unrar") != nil {
            rarBackend = .unrar
        } else if findExecutable("7zz") != nil || findExecutable("7z") != nil {
            rarBackend = .sevenZip
        } else {
            rarBackend = .bsdtar
        }
        return BackendStatus(zipEngine: "ditto / unzip (native)", rarBackend: rarBackend)
    }

    func inspect(url: URL) async throws -> ArchiveMetadata {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ArchiveEngineError.fileNotFound(url)
        }
        guard let format = ArchiveFormat.detect(from: url) else {
            throw ArchiveEngineError.unsupportedFormat(url.pathExtension)
        }

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let compressedSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        let (entries, encrypted): ([ArchiveEntry], Bool)
        switch format {
        case .zip:
            (entries, encrypted) = try await inspectZip(url: url)
        case .rar:
            (entries, encrypted) = try await inspectRar(url: url)
        case .sevenZip:
            (entries, encrypted) = try await inspectSevenZip(url: url)
        case .tar:
            (entries, encrypted) = try await inspectTar(url: url)
        }

        return ArchiveMetadata(
            url: url,
            format: format,
            compressedSize: compressedSize,
            entries: entries,
            isEncrypted: encrypted
        )
    }

    func extract(
        url: URL,
        toParent destinationParent: URL,
        password: String? = nil,
        expectedEntries: [ArchiveEntry] = [],
        skipEncryptionProbe: Bool = false,
        conflictPolicy: ConflictPolicy = .rename,
        onProgress: @escaping @Sendable (Double?, String) -> Void
    ) async throws -> (outputURL: URL, itemCount: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ArchiveEngineError.fileNotFound(url)
        }
        guard let format = ArchiveFormat.detect(from: url) else {
            throw ArchiveEngineError.unsupportedFormat(url.pathExtension)
        }

        let stagingName = ".maczipper-staging-\(UUID().uuidString)"
        let stagingDir = destinationParent.appendingPathComponent(stagingName, isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var movedOutput = false
        defer {
            if !movedOutput {
                try? fm.removeItem(at: stagingDir)
            }
        }

        let tracker = ExtractionProgressTracker(entries: expectedEntries, onProgress: onProgress)
        onProgress(expectedEntries.isEmpty ? nil : 0.02, "Extracting \(url.lastPathComponent)…")

        switch format {
        case .zip:
            try await extractZip(
                url: url,
                to: stagingDir,
                password: password,
                skipEncryptionProbe: skipEncryptionProbe,
                tracker: tracker
            )
        case .rar:
            try await extractRar(url: url, to: stagingDir, password: password, tracker: tracker)
        case .sevenZip:
            try await extractSevenZip(url: url, to: stagingDir, password: password, tracker: tracker)
        case .tar:
            try await extractTar(url: url, to: stagingDir, tracker: tracker)
        }

        try Task.checkCancellation()
        onProgress(0.95, "Finalizing files…")

        // Remove __MACOSX junk if present
        let macosxJunk = stagingDir.appendingPathComponent("__MACOSX")
        if fm.fileExists(atPath: macosxJunk.path) {
            try? fm.removeItem(at: macosxJunk)
        }

        let topItems = try fm.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let baseName = stripArchiveExtension(from: url.lastPathComponent)
        let finalURL: URL

        if topItems.count == 1,
           let onlyItem = topItems.first,
           (try? onlyItem.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            // Single top-level folder: move it directly without double-nesting
            let desiredName = onlyItem.lastPathComponent
            let target = try resolveDestination(in: destinationParent, preferredName: desiredName, policy: conflictPolicy)
            try fm.moveItem(at: onlyItem, to: target)
            try? fm.removeItem(at: stagingDir)
            movedOutput = true
            finalURL = target
        } else {
            let target = try resolveDestination(in: destinationParent, preferredName: baseName, policy: conflictPolicy)
            try fm.moveItem(at: stagingDir, to: target)
            movedOutput = true
            finalURL = target
        }

        let itemCount = countItems(in: finalURL)
        onProgress(1.0, "Done")
        return (finalURL, itemCount)
    }

    // MARK: - ZIP Inspection & Extraction

    private func inspectZip(url: URL) async throws -> ([ArchiveEntry], Bool) {
        if let unzipURL = findExecutable("unzip") {
            let result = try await runProcess(
                executable: unzipURL,
                arguments: ["-Z", "-l", url.path]
            )
            if result.exitCode == 0 || !result.stdout.isEmpty {
                return parseUnzipList(result.stdout)
            }
        }

        if let tarURL = findExecutable("tar") {
            let result = try await runProcess(
                executable: tarURL,
                arguments: ["-tvf", url.path]
            )
            if result.exitCode == 0 {
                return (parseTarList(result.stdout), false)
            }
        }

        return ([], false)
    }

    private func extractZip(
        url: URL,
        to destination: URL,
        password: String?,
        skipEncryptionProbe: Bool,
        tracker: ExtractionProgressTracker
    ) async throws {
        // Use unzip when a password is provided, otherwise prefer ditto for macOS metadata & UTF-8 fidelity.
        if let password, !password.isEmpty {
            guard let unzipURL = findExecutable("unzip") else {
                throw ArchiveEngineError.extractionFailed("unzip binary not found.", suggestUnar: false)
            }
            let result = try await runProcess(
                executable: unzipURL,
                arguments: ["-o", "-P", password, url.path, "-d", destination.path],
                onOutputLine: { line in
                    tracker.handleUnzipLine(line)
                }
            )
            if result.exitCode != 0 {
                let combined = (result.stderr + "\n" + result.stdout).lowercased()
                if combined.contains("incorrect password") || combined.contains("skipping:") {
                    throw ArchiveEngineError.wrongPassword
                }
                throw ArchiveEngineError.extractionFailed(
                    cleanErrorMessage(result.stderr, fallback: result.stdout),
                    suggestUnar: false
                )
            }
            return
        }

        // Check if encrypted before calling ditto only if we haven't already inspected it.
        if !skipEncryptionProbe, let unzipURL = findExecutable("unzip") {
            let probe = try await runProcess(executable: unzipURL, arguments: ["-Z", "-l", url.path])
            let (_, isEncrypted) = parseUnzipList(probe.stdout)
            if isEncrypted {
                throw ArchiveEngineError.passwordRequired("Enter password to unlock this ZIP archive.")
            }
        }

        if let dittoURL = findExecutable("ditto") {
            let result = try await runProcess(
                executable: dittoURL,
                arguments: ["-V", "-x", "-k", url.path, destination.path],
                onOutputLine: { line in
                    tracker.handleDittoLine(line)
                }
            )
            if result.exitCode == 0 {
                return
            }
            let combined = (result.stderr + "\n" + result.stdout).lowercased()
            if combined.contains("password") || combined.contains("encrypted") {
                throw ArchiveEngineError.passwordRequired("Enter password to unlock this ZIP archive.")
            }
            // Fallback to unzip if ditto fails on an unusual zip variant
            if let unzipURL = findExecutable("unzip") {
                let fallback = try await runProcess(
                    executable: unzipURL,
                    arguments: ["-o", url.path, "-d", destination.path],
                    onOutputLine: { line in
                        tracker.handleUnzipLine(line)
                    }
                )
                if fallback.exitCode == 0 {
                    return
                }
            }
            throw ArchiveEngineError.extractionFailed(
                cleanErrorMessage(result.stderr, fallback: result.stdout),
                suggestUnar: false
            )
        }
    }

    // MARK: - RAR Inspection & Extraction

    private func inspectRar(url: URL) async throws -> ([ArchiveEntry], Bool) {
        if let lsarURL = findExecutable("lsar") {
            let result = try await runProcess(
                executable: lsarURL,
                arguments: ["-json", url.path]
            )
            if result.exitCode == 0, let parsed = parseLsarJSON(result.stdout) {
                return parsed
            }
        }

        if let tarURL = findExecutable("tar") {
            let result = try await runProcess(
                executable: tarURL,
                arguments: ["-tvf", url.path]
            )
            if result.exitCode == 0 {
                return (parseTarList(result.stdout), false)
            }
        }

        return ([], false)
    }

    private func extractRar(url: URL, to destination: URL, password: String?, tracker: ExtractionProgressTracker) async throws {
        if let unarURL = findExecutable("unar") {
            var args = ["-force-overwrite", "-no-directory", "-o", destination.path]
            if let password, !password.isEmpty {
                args.append(contentsOf: ["-password", password])
            }
            args.append(url.path)

            let result = try await runProcess(
                executable: unarURL,
                arguments: args,
                onOutputLine: { line in
                    tracker.handleUnarLine(line)
                }
            )
            if result.exitCode == 0 {
                return
            }
            let combined = (result.stderr + "\n" + result.stdout).lowercased()
            if combined.contains("password") || combined.contains("passphrase") || combined.contains("encrypted") {
                if password != nil {
                    throw ArchiveEngineError.wrongPassword
                }
                throw ArchiveEngineError.passwordRequired("Enter password to unlock this RAR archive.")
            }
            throw ArchiveEngineError.extractionFailed(
                cleanErrorMessage(result.stderr, fallback: result.stdout),
                suggestUnar: false
            )
        }

        if let unrarURL = findExecutable("unrar") {
            var args = ["x", "-o+"]
            if let password, !password.isEmpty {
                args.append("-p\(password)")
            } else {
                args.append("-p-")
            }
            args.append(url.path)
            args.append(destination.path + "/")

            let result = try await runProcess(
                executable: unrarURL,
                arguments: args,
                onOutputLine: { line in
                    tracker.handleUnrarLine(line)
                }
            )
            if result.exitCode == 0 {
                return
            }
            let combined = (result.stderr + "\n" + result.stdout).lowercased()
            if combined.contains("password") || combined.contains("encrypted") {
                if password != nil {
                    throw ArchiveEngineError.wrongPassword
                }
                throw ArchiveEngineError.passwordRequired("Enter password to unlock this RAR archive.")
            }
            throw ArchiveEngineError.extractionFailed(
                cleanErrorMessage(result.stderr, fallback: result.stdout),
                suggestUnar: false
            )
        }

        if let sevenZipURL = findExecutable("7zz") ?? findExecutable("7z") {
            var args = ["x", "-y", "-bsp1", "-o\(destination.path)"]
            if let password, !password.isEmpty {
                args.append("-p\(password)")
            } else {
                args.append("-p")
            }
            args.append(url.path)

            let result = try await runProcess(
                executable: sevenZipURL,
                arguments: args,
                onOutputLine: { line in
                    tracker.handleSevenZipLine(line)
                }
            )
            if result.exitCode == 0 {
                return
            }
            let combined = (result.stderr + "\n" + result.stdout).lowercased()
            if combined.contains("wrong password") || combined.contains("password") {
                if password != nil {
                    throw ArchiveEngineError.wrongPassword
                }
                throw ArchiveEngineError.passwordRequired("Enter password to unlock this RAR archive.")
            }
            throw ArchiveEngineError.extractionFailed(
                cleanErrorMessage(result.stderr, fallback: result.stdout),
                suggestUnar: true
            )
        }

        // Built-in bsdtar fallback
        guard let tarURL = findExecutable("tar") else {
            throw ArchiveEngineError.extractionFailed("No RAR extractor available.", suggestUnar: true)
        }
        let result = try await runProcess(
            executable: tarURL,
            arguments: ["-xvf", url.path, "-C", destination.path],
            onOutputLine: { line in
                tracker.handleTarLine(line)
            }
        )
        if result.exitCode == 0 {
            return
        }
        let msg = cleanErrorMessage(result.stderr, fallback: result.stdout)
        let lower = msg.lowercased()
        if lower.contains("passphrase") || lower.contains("encrypted") || lower.contains("password") {
            throw ArchiveEngineError.extractionFailed(
                "Encrypted RAR archives require unar. Install with: brew install unar",
                suggestUnar: true
            )
        }
        throw ArchiveEngineError.extractionFailed(
            msg.isEmpty ? "Built-in bsdtar could not extract this RAR variant. Install unar for full RAR5 support." : msg,
            suggestUnar: true
        )
    }

    // MARK: - 7Z & TAR Inspection & Extraction

    private func inspectSevenZip(url: URL) async throws -> ([ArchiveEntry], Bool) {
        if let lsarURL = findExecutable("lsar") {
            let result = try await runProcess(executable: lsarURL, arguments: ["-json", url.path])
            if result.exitCode == 0, let parsed = parseLsarJSON(result.stdout) {
                return parsed
            }
        }
        if let tarURL = findExecutable("tar") {
            let result = try await runProcess(executable: tarURL, arguments: ["-tvf", url.path])
            if result.exitCode == 0 {
                return (parseTarList(result.stdout), false)
            }
        }
        return ([], false)
    }

    private func extractSevenZip(
        url: URL,
        to destination: URL,
        password: String?,
        tracker: ExtractionProgressTracker
    ) async throws {
        if let sevenZipURL = findExecutable("7zz") ?? findExecutable("7z") {
            var args = ["x", "-y", "-bsp1", "-o\(destination.path)"]
            if let password, !password.isEmpty {
                args.append("-p\(password)")
            } else {
                args.append("-p")
            }
            args.append(url.path)

            let result = try await runProcess(
                executable: sevenZipURL,
                arguments: args,
                onOutputLine: { line in tracker.handleSevenZipLine(line) }
            )
            if result.exitCode == 0 { return }
            let combined = (result.stderr + "\n" + result.stdout).lowercased()
            if combined.contains("wrong password") || combined.contains("password") {
                if password != nil { throw ArchiveEngineError.wrongPassword }
                throw ArchiveEngineError.passwordRequired("Enter password to unlock this 7Z archive.")
            }
            throw ArchiveEngineError.extractionFailed(
                cleanErrorMessage(result.stderr, fallback: result.stdout),
                suggestUnar: false
            )
        }

        if let unarURL = findExecutable("unar") {
            var args = ["-force-overwrite", "-no-directory", "-o", destination.path]
            if let password, !password.isEmpty {
                args.append(contentsOf: ["-password", password])
            }
            args.append(url.path)
            let result = try await runProcess(
                executable: unarURL,
                arguments: args,
                onOutputLine: { line in tracker.handleUnarLine(line) }
            )
            if result.exitCode == 0 { return }
            let combined = (result.stderr + "\n" + result.stdout).lowercased()
            if combined.contains("password") || combined.contains("encrypted") {
                if password != nil { throw ArchiveEngineError.wrongPassword }
                throw ArchiveEngineError.passwordRequired("Enter password to unlock this 7Z archive.")
            }
            throw ArchiveEngineError.extractionFailed(
                cleanErrorMessage(result.stderr, fallback: result.stdout),
                suggestUnar: false
            )
        }

        guard let tarURL = findExecutable("tar") else {
            throw ArchiveEngineError.extractionFailed("No 7Z extractor available.", suggestUnar: true)
        }
        let result = try await runProcess(
            executable: tarURL,
            arguments: ["-xvf", url.path, "-C", destination.path],
            onOutputLine: { line in tracker.handleTarLine(line) }
        )
        if result.exitCode == 0 { return }
        throw ArchiveEngineError.extractionFailed(
            cleanErrorMessage(result.stderr, fallback: result.stdout),
            suggestUnar: true
        )
    }

    private func inspectTar(url: URL) async throws -> ([ArchiveEntry], Bool) {
        guard let tarURL = findExecutable("tar") else { return ([], false) }
        let result = try await runProcess(executable: tarURL, arguments: ["-tvf", url.path])
        if result.exitCode == 0 {
            return (parseTarList(result.stdout), false)
        }
        return ([], false)
    }

    private func extractTar(url: URL, to destination: URL, tracker: ExtractionProgressTracker) async throws {
        guard let tarURL = findExecutable("tar") else {
            throw ArchiveEngineError.extractionFailed("Built-in tar binary not found.", suggestUnar: false)
        }
        let result = try await runProcess(
            executable: tarURL,
            arguments: ["-xvf", url.path, "-C", destination.path],
            onOutputLine: { line in tracker.handleTarLine(line) }
        )
        if result.exitCode == 0 { return }
        throw ArchiveEngineError.extractionFailed(
            cleanErrorMessage(result.stderr, fallback: result.stdout),
            suggestUnar: false
        )
    }

    // MARK: - Parsers

    private func parseUnzipList(_ output: String) -> ([ArchiveEntry], Bool) {
        var entries: [ArchiveEntry] = []
        var isEncrypted = false

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("Archive:"),
                  !trimmed.hasPrefix("Zip file size:"),
                  !trimmed.hasSuffix("files") else {
                continue
            }

            // zipinfo -l format: permissions version os uncompressed_size flag ... path
            let parts = trimmed.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count >= 9 else { continue }

            let perms = String(parts[0])
            guard perms.count >= 4, perms.first == "-" || perms.first == "d" || perms.first == "l" else {
                continue
            }
            let size = Int64(parts[3]) ?? 0
            let encFlag = String(parts[4])
            let path = String(parts[8])

            if path.hasPrefix("__MACOSX/") || path == "__MACOSX" || (path as NSString).lastPathComponent.hasPrefix("._") {
                continue
            }

            // Uppercase first char in zipinfo encryption/method field (e.g. "B-", "T-") indicates encrypted entry
            if let first = encFlag.first, first.isUppercase {
                isEncrypted = true
            }

            let isDir = perms.hasPrefix("d") || path.hasSuffix("/")
            entries.append(ArchiveEntry(id: path, path: path, size: size, isDirectory: isDir))
        }

        return (entries, isEncrypted)
    }

    private func parseTarList(_ output: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // bsdtar -tvf: perms links owner group size month day time/year path
            let parts = trimmed.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count >= 9 else { continue }

            let perms = String(parts[0])
            let size = Int64(parts[4]) ?? 0
            let path = String(parts[8])
            if path.hasPrefix("__MACOSX/") || path == "__MACOSX" { continue }

            let isDir = perms.hasPrefix("d") || path.hasSuffix("/")
            entries.append(ArchiveEntry(id: path, path: path, size: size, isDirectory: isDir))
        }
        return entries
    }

    private func parseLsarJSON(_ jsonString: String) -> ([ArchiveEntry], Bool)? {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contents = root["lsarContents"] as? [[String: Any]] else {
            return nil
        }

        var entries: [ArchiveEntry] = []
        var isEncrypted = false

        for item in contents {
            guard let path = item["XADFileName"] as? String else { continue }
            let size = (item["XADFileSize"] as? NSNumber)?.int64Value ?? 0
            let isDir = (item["XADIsDirectory"] as? Bool) ?? path.hasSuffix("/")
            if (item["XADIsEncrypted"] as? Bool) == true {
                isEncrypted = true
            }
            entries.append(ArchiveEntry(id: path, path: path, size: size, isDirectory: isDir))
        }

        return (entries, isEncrypted)
    }

    // MARK: - Helpers

    private func resolveDestination(
        in parent: URL,
        preferredName: String,
        policy: ConflictPolicy
    ) throws -> URL {
        let fm = FileManager.default
        let sanitized = preferredName.isEmpty ? "Extracted" : preferredName
        let exactCandidate = parent.appendingPathComponent(sanitized)

        switch policy {
        case .replace:
            if fm.fileExists(atPath: exactCandidate.path) {
                try fm.trashItem(at: exactCandidate, resultingItemURL: nil)
            }
            return exactCandidate
        case .rename:
            var candidate = exactCandidate
            var counter = 2
            while fm.fileExists(atPath: candidate.path) {
                candidate = parent.appendingPathComponent("\(sanitized) \(counter)")
                counter += 1
            }
            return candidate
        }
    }

    private func stripArchiveExtension(from fileName: String) -> String {
        let lower = fileName.lowercased()
        for compound in [".tar.gz", ".tar.bz2", ".tar.xz"] {
            if lower.hasSuffix(compound) {
                return String(fileName.dropLast(compound.count))
            }
        }
        return (fileName as NSString).deletingPathExtension
    }

    private func countItems(in url: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 1
        }
        var count = 0
        for case let itemURL as URL in enumerator {
            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir {
                count += 1
            }
        }
        return max(count, 1)
    }

    private func cleanErrorMessage(_ stderr: String, fallback: String) -> String {
        let primary = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = primary.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : primary
        let firstLine = text.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        return firstLine ?? "Extraction failed."
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        // Prevent interactive prompts from hanging the process
        let nullInput = FileHandle.nullDevice
        process.standardInput = nullInput

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = StreamCollector(onLine: onOutputLine)
        if onOutputLine != nil {
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    collector.appendStdout(data)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    collector.appendStderr(data)
                }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let outRemaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errRemaining = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    collector.appendStdout(outRemaining)
                    collector.appendStderr(errRemaining)

                    let (stdout, stderr) = collector.finalize()
                    continuation.resume(returning: CommandResult(
                        exitCode: proc.terminationStatus,
                        stdout: stdout,
                        stderr: stderr
                    ))
                }
                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stdoutLineBuffer = ""
    private var stderrLineBuffer = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        var linesToEmit: [String] = []
        lock.lock()
        stdoutBuffer.append(data)
        if onLine != nil {
            let chunk = String(decoding: data, as: UTF8.self)
            stdoutLineBuffer.append(chunk)
            linesToEmit = Self.drainLines(from: &stdoutLineBuffer)
        }
        lock.unlock()
        for line in linesToEmit {
            onLine?(line)
        }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        var linesToEmit: [String] = []
        lock.lock()
        stderrBuffer.append(data)
        if onLine != nil {
            let chunk = String(decoding: data, as: UTF8.self)
            stderrLineBuffer.append(chunk)
            linesToEmit = Self.drainLines(from: &stderrLineBuffer)
        }
        lock.unlock()
        for line in linesToEmit {
            onLine?(line)
        }
    }

    func finalize() -> (String, String) {
        var trailing: [String] = []
        lock.lock()
        if onLine != nil {
            if !stdoutLineBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                trailing.append(stdoutLineBuffer)
                stdoutLineBuffer = ""
            }
            if !stderrLineBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                trailing.append(stderrLineBuffer)
                stderrLineBuffer = ""
            }
        }
        let stdout = String(data: stdoutBuffer, encoding: .utf8) ?? ""
        let stderr = String(data: stderrBuffer, encoding: .utf8) ?? ""
        lock.unlock()

        for line in trailing {
            onLine?(line)
        }
        return (stdout, stderr)
    }

    private static func drainLines(from buffer: inout String) -> [String] {
        var lines: [String] = []
        let normalized = buffer.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var parts = normalized.components(separatedBy: "\n")
        if let remainder = parts.popLast() {
            buffer = remainder
        } else {
            buffer = ""
        }
        for part in parts where !part.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append(part)
        }
        return lines
    }
}

private final class ExtractionProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalFiles: Int
    private let totalBytes: Int64
    private let sizeByNormalizedPath: [String: Int64]
    private let sizeByFileName: [String: Int64]
    private var matchedKeys: Set<String> = []
    private var completedFiles = 0
    private var completedBytes: Int64 = 0
    private var lastReportedFraction: Double = 0
    private var lastEmitTime: CFAbsoluteTime = 0
    private let emitInterval: CFAbsoluteTime = 0.04
    private let onProgress: @Sendable (Double?, String) -> Void

    init(entries: [ArchiveEntry], onProgress: @escaping @Sendable (Double?, String) -> Void) {
        let files = entries.filter { !$0.isDirectory }
        self.totalFiles = files.count
        self.totalBytes = files.reduce(0) { $0 + max($1.size, 0) }
        self.onProgress = onProgress

        var byPath: [String: Int64] = [:]
        var byName: [String: Int64] = [:]
        for entry in files {
            let norm = Self.normalizePath(entry.path)
            byPath[norm] = max(entry.size, 0)
            let name = (norm as NSString).lastPathComponent
            if byName[name] == nil {
                byName[name] = max(entry.size, 0)
            }
        }
        self.sizeByNormalizedPath = byPath
        self.sizeByFileName = byName
    }

    func handleDittoLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // ditto -V prints: "copying <path>" or "ditto: ..."
        if trimmed.hasPrefix("copying ") {
            let rawPath = String(trimmed.dropFirst("copying ".count)).trimmingCharacters(in: .whitespaces)
            recordExtractedItem(rawPath: rawPath)
        }
    }

    func handleUnzipLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["inflating: ", "extracting: "] {
            if trimmed.hasPrefix(prefix) {
                let rawPath = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                recordExtractedItem(rawPath: rawPath)
                return
            }
        }
    }

    func handleTarLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("x ") {
            let rawPath = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !rawPath.hasSuffix("/") {
                recordExtractedItem(rawPath: rawPath)
            }
        }
    }

    func handleUnarLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // unar prints: "<path>  (<size>)... OK." or "<path>... OK."
        if trimmed.hasSuffix("OK.") || trimmed.contains("... OK") {
            let cleaned = trimmed
                .replacingOccurrences(of: "... OK.", with: "")
                .trimmingCharacters(in: .whitespaces)
            let pathPart = cleaned.components(separatedBy: "  (").first ?? cleaned
            if !pathPart.isEmpty && !pathPart.hasSuffix("/") {
                recordExtractedItem(rawPath: pathPart)
            }
        }
    }

    func handleUnrarLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Extracting ") {
            let rest = String(trimmed.dropFirst("Extracting ".count)).trimmingCharacters(in: .whitespaces)
            let pathPart = rest.replacingOccurrences(of: " OK", with: "").trimmingCharacters(in: .whitespaces)
            if !pathPart.isEmpty {
                recordExtractedItem(rawPath: pathPart)
            }
        }
    }

    func handleSevenZipLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // 7zz -bsp1 prints percentages like " 42% ..."
        if let pctRange = trimmed.range(of: #"(\d{1,3})%"#, options: .regularExpression),
           let pct = Double(trimmed[pctRange].dropLast()) {
            let fraction = min(max(pct / 100.0 * 0.94, 0.02), 0.94)
            lock.lock()
            let shouldEmit = fraction > lastReportedFraction
            if shouldEmit {
                lastReportedFraction = fraction
            }
            lock.unlock()
            if shouldEmit {
                onProgress(fraction, "Extracting… \(Int(pct))%")
            }
        }
    }

    private func recordExtractedItem(rawPath: String) {
        let norm = Self.normalizePath(rawPath)
        guard !norm.isEmpty else { return }
        let fileName = (norm as NSString).lastPathComponent
        if fileName.hasPrefix("._") || norm.hasPrefix("__MACOSX") { return }

        lock.lock()
        let key = norm
        if !matchedKeys.contains(key) {
            matchedKeys.insert(key)
            completedFiles += 1
            if let exactSize = sizeByNormalizedPath[norm] {
                completedBytes += exactSize
            } else if let suffixMatch = sizeByNormalizedPath.first(where: { norm.hasSuffix("/" + $0.key) || $0.key.hasSuffix("/" + norm) }) {
                completedBytes += suffixMatch.value
            } else if let nameSize = sizeByFileName[fileName] {
                completedBytes += nameSize
            }
        }

        let fraction: Double?
        if totalBytes > 0 {
            let ratio = Double(completedBytes) / Double(totalBytes)
            fraction = min(max(ratio * 0.94, 0.03), 0.94)
        } else if totalFiles > 0 {
            let ratio = Double(completedFiles) / Double(totalFiles)
            fraction = min(max(ratio * 0.94, 0.03), 0.94)
        } else {
            fraction = nil
        }

        let now = CFAbsoluteTimeGetCurrent()
        let isFinalItem = totalFiles > 0 && completedFiles >= totalFiles
        let jumpedSignificantly = (fraction ?? 0) - lastReportedFraction >= 0.05
        let shouldEmit = (now - lastEmitTime) >= emitInterval || isFinalItem || jumpedSignificantly

        if let fraction {
            lastReportedFraction = max(lastReportedFraction, fraction)
        }
        let reportedFraction = fraction.map { max($0, lastReportedFraction) }
        let countText = totalFiles > 0 ? " (\(min(completedFiles, totalFiles))/\(totalFiles))" : ""
        if shouldEmit {
            lastEmitTime = now
        }
        lock.unlock()

        if shouldEmit {
            onProgress(reportedFraction, "Extracting \(fileName)\(countText)")
        }
    }

    private static func normalizePath(_ path: String) -> String {
        var s = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("./") {
            s.removeFirst(2)
        }
        while s.hasPrefix("/") {
            s.removeFirst()
        }
        return s
    }
}
