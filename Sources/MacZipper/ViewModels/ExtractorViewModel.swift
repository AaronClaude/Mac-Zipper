import AppKit
import Foundation
import SwiftUI

@MainActor
final class ExtractorViewModel: ObservableObject {
    @Published var archiveURL: URL?
    @Published var metadata: ArchiveMetadata?
    @Published var destinationParent: URL?
    @Published var state: ExtractionState = .idle
    @Published var passwordInput: String = ""
    @Published var showContents: Bool = false
    @Published var queuedURLs: [URL] = []
    @Published var backendStatus: BackendStatus

    @AppStorage("autoExtractOnDrop") var autoExtractOnDrop: Bool = true
    @AppStorage("revealInFinder") var revealInFinder: Bool = true
    @AppStorage("trashArchiveAfterExtract") var trashArchiveAfterExtract: Bool = false
    @AppStorage("autoQuitAfterExtract") var autoQuitAfterExtract: Bool = false
    @AppStorage("conflictPolicy") var conflictPolicyRaw: String = ConflictPolicy.rename.rawValue
    @AppStorage("customOutputPath") var customOutputPath: String = ""

    var conflictPolicy: ConflictPolicy {
        get { ConflictPolicy(rawValue: conflictPolicyRaw) ?? .rename }
        set { conflictPolicyRaw = newValue.rawValue }
    }

    var hasCustomOutputFolder: Bool {
        !customOutputPath.isEmpty && FileManager.default.fileExists(atPath: customOutputPath)
    }

    var defaultOutputDisplayPath: String {
        if hasCustomOutputFolder {
            return (customOutputPath as NSString).abbreviatingWithTildeInPath
        }
        return "Same as archive"
    }

    private let engine = ArchiveEngine.shared
    private var activeTask: Task<Void, Never>?

    init() {
        self.backendStatus = engine.backendStatus()
    }

    func refreshBackendStatus() {
        backendStatus = engine.backendStatus()
    }

    func handleIncomingURLs(_ urls: [URL]) {
        let supported = filterPrimaryArchives(urls.filter { ArchiveFormat.detect(from: $0) != nil })
        guard let first = supported.first else {
            if let invalid = urls.first {
                state = .failed(
                    message: "Unsupported file “\(invalid.lastPathComponent)”. Supported: .zip, .rar, .7z, .tar",
                    canInstallUnar: false
                )
            }
            return
        }

        if supported.count > 1 {
            queuedURLs = Array(supported.dropFirst())
        } else {
            queuedURLs = []
        }

        loadArchive(first)
    }

    private func filterPrimaryArchives(_ urls: [URL]) -> [URL] {
        // Ignore secondary multi-part RAR volumes (e.g., .part2.rar, .part03.rar) when queuing.
        urls.filter { url in
            let lower = url.lastPathComponent.lowercased()
            if let range = lower.range(of: #"\.part(\d+)\.rar$"#, options: .regularExpression) {
                let digits = lower[range]
                    .replacingOccurrences(of: ".part", with: "")
                    .replacingOccurrences(of: ".rar", with: "")
                return Int(digits) == 1
            }
            return true
        }
    }

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let exts = ["zip", "rar", "7z", "tar", "tgz", "gz", "bz2", "tbz2", "xz", "txz"]
        panel.allowedContentTypes = exts.compactMap { .init(filenameExtension: $0) }
        panel.message = "Select an archive (.zip, .rar, .7z, .tar) to extract"

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            handleIncomingURLs(panel.urls)
        }
    }

    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationParent
            ?? (hasCustomOutputFolder ? URL(fileURLWithPath: customOutputPath) : nil)
            ?? archiveURL?.deletingLastPathComponent()
        panel.message = "Choose output folder for extracted files"
        panel.prompt = "Select Folder"

        if panel.runModal() == .OK, let url = panel.url {
            destinationParent = url
            customOutputPath = url.path
        }
    }

    func resetDefaultOutputFolder() {
        customOutputPath = ""
        if let archiveURL {
            destinationParent = archiveURL.deletingLastPathComponent()
        } else {
            destinationParent = nil
        }
    }

    func loadArchive(_ url: URL) {
        activeTask?.cancel()
        archiveURL = url
        metadata = nil
        passwordInput = ""
        showContents = false
        if hasCustomOutputFolder {
            destinationParent = URL(fileURLWithPath: customOutputPath, isDirectory: true)
        } else {
            destinationParent = url.deletingLastPathComponent()
        }
        state = .inspecting(url)
        refreshBackendStatus()

        activeTask = Task {
            do {
                let meta = try await engine.inspect(url: url)
                guard !Task.isCancelled else { return }
                self.metadata = meta

                if meta.isEncrypted {
                    self.state = .needsPassword(message: "This archive is password protected.")
                } else if self.autoExtractOnDrop {
                    self.startExtraction()
                } else {
                    self.state = .ready
                }
            } catch is CancellationError {
                self.state = .idle
            } catch {
                self.state = .failed(message: error.localizedDescription, canInstallUnar: false)
            }
        }
    }

    func startExtraction(withPassword password: String? = nil) {
        guard let url = archiveURL else { return }
        let targetParent = destinationParent ?? url.deletingLastPathComponent()

        activeTask?.cancel()
        state = .extracting(progress: nil, status: "Preparing…")

        activeTask = Task {
            do {
                let skipProbe = (self.metadata?.isEncrypted == false)
                let result = try await engine.extract(
                    url: url,
                    toParent: targetParent,
                    password: password,
                    expectedEntries: metadata?.entries ?? [],
                    skipEncryptionProbe: skipProbe,
                    conflictPolicy: self.conflictPolicy
                ) { progress, status in
                    Task { @MainActor in
                        if case .extracting = self.state {
                            self.state = .extracting(progress: progress, status: status)
                        }
                    }
                }

                guard !Task.isCancelled else { return }

                if self.trashArchiveAfterExtract {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }

                self.passwordInput = ""
                self.state = .completed(outputURL: result.outputURL, itemCount: result.itemCount)

                if self.revealInFinder {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }

                if !self.queuedURLs.isEmpty {
                    let next = self.queuedURLs.removeFirst()
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    self.loadArchive(next)
                } else if self.autoQuitAfterExtract {
                    try? await Task.sleep(for: .milliseconds(650))
                    guard !Task.isCancelled else { return }
                    NSApp.terminate(nil)
                }
            } catch is CancellationError {
                self.state = .ready
            } catch ArchiveEngineError.passwordRequired(let msg) {
                self.state = .needsPassword(message: msg)
            } catch ArchiveEngineError.wrongPassword {
                self.passwordInput = ""
                self.state = .needsPassword(message: "Incorrect password. Please try again.")
            } catch ArchiveEngineError.extractionFailed(let msg, let suggestUnar) {
                self.state = .failed(message: msg, canInstallUnar: suggestUnar)
            } catch {
                self.state = .failed(message: error.localizedDescription, canInstallUnar: false)
            }
        }
    }

    func submitPassword() {
        let trimmed = passwordInput
        guard !trimmed.isEmpty else { return }
        startExtraction(withPassword: trimmed)
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        if metadata != nil {
            state = .ready
        } else {
            reset()
        }
    }

    func reset() {
        activeTask?.cancel()
        activeTask = nil
        archiveURL = nil
        metadata = nil
        destinationParent = nil
        passwordInput = ""
        showContents = false
        queuedURLs = []
        state = .idle
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copyBrewInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install unar", forType: .string)
    }
}
