import Foundation
import Testing
@testable import MacZipper

@Suite("ArchiveEngine Tests")
struct ArchiveEngineTests {
    @Test("Format detection handles zip, rar, 7z, tar variants, and unsupported files")
    func formatDetection() {
        #expect(ArchiveFormat.detect(from: URL(fileURLWithPath: "/tmp/test.zip")) == .zip)
        #expect(ArchiveFormat.detect(from: URL(fileURLWithPath: "/tmp/test.ZIP")) == .zip)
        #expect(ArchiveFormat.detect(from: URL(fileURLWithPath: "/tmp/test.rar")) == .rar)
        #expect(ArchiveFormat.detect(from: URL(fileURLWithPath: "/tmp/test.RAR")) == .rar)
        #expect(ArchiveFormat.detect(from: URL(fileURLWithPath: "/tmp/test.7z")) == .sevenZip)
        #expect(ArchiveFormat.detect(from: URL(fileURLWithPath: "/tmp/test.tar.gz")) == .tar)
        #expect(ArchiveFormat.detect(from: URL(fileURLWithPath: "/tmp/test.tgz")) == .tar)
        #expect(ArchiveFormat.detect(from: URL(fileURLWithPath: "/tmp/test.tar.xz")) == .tar)
        #expect(ArchiveFormat.detect(from: URL(fileURLWithPath: "/tmp/test.tar")) == .tar)
        #expect(ArchiveFormat.detect(from: URL(fileURLWithPath: "/tmp/test.txt")) == nil)
    }

    @Test("Inspect and extract ZIP archive without double-nesting")
    func inspectAndExtractZip() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("MacZipperTest-\(UUID().uuidString)")
        let sourceDir = tempRoot.appendingPathComponent("SampleFolder")
        let destDir = tempRoot.appendingPathComponent("Output")
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let fileA = sourceDir.appendingPathComponent("hello.txt")
        let fileB = sourceDir.appendingPathComponent("notes.md")
        try "Hello MacZipper".write(to: fileA, atomically: true, encoding: .utf8)
        try "# Notes".write(to: fileB, atomically: true, encoding: .utf8)

        let zipURL = tempRoot.appendingPathComponent("SampleFolder.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", sourceDir.path, zipURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)

        let engine = ArchiveEngine.shared
        let metadata = try await engine.inspect(url: zipURL)
        #expect(metadata.format == .zip)
        #expect(metadata.isEncrypted == false)
        #expect(metadata.fileCount == 2)

        let progressBox = ProgressRecorder()
        let firstResult = try await engine.extract(
            url: zipURL,
            toParent: destDir,
            expectedEntries: metadata.entries
        ) { progress, _ in
            if let progress {
                progressBox.record(progress)
            }
        }
        #expect(firstResult.outputURL.lastPathComponent == "SampleFolder")
        #expect(firstResult.itemCount == 2)
        #expect(progressBox.values.last == 1.0)
        #expect(progressBox.values.count >= 2)
        let extractedHello = firstResult.outputURL.appendingPathComponent("hello.txt")
        #expect(try String(contentsOf: extractedHello, encoding: .utf8) == "Hello MacZipper")

        // Second extraction to same directory should avoid collision by appending " 2"
        let secondResult = try await engine.extract(
            url: zipURL,
            toParent: destDir,
            skipEncryptionProbe: true,
            conflictPolicy: .rename
        ) { _, _ in }
        #expect(secondResult.outputURL.lastPathComponent == "SampleFolder 2")

        // Third extraction with .replace should reuse "SampleFolder"
        let replaceResult = try await engine.extract(
            url: zipURL,
            toParent: destDir,
            skipEncryptionProbe: true,
            conflictPolicy: .replace
        ) { _, _ in }
        #expect(replaceResult.outputURL.lastPathComponent == "SampleFolder")
    }

    @Test("Inspect and extract tar.gz archive")
    func inspectAndExtractTarGz() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("MacZipperTarTest-\(UUID().uuidString)")
        let sourceDir = tempRoot.appendingPathComponent("TarFolder")
        let destDir = tempRoot.appendingPathComponent("Output")
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        try "tar content".write(to: sourceDir.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let tarURL = tempRoot.appendingPathComponent("TarFolder.tar.gz")
        let tarProc = Process()
        tarProc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarProc.arguments = ["-czf", tarURL.path, "-C", tempRoot.path, "TarFolder"]
        try tarProc.run()
        tarProc.waitUntilExit()
        #expect(tarProc.terminationStatus == 0)

        let engine = ArchiveEngine.shared
        let meta = try await engine.inspect(url: tarURL)
        #expect(meta.format == .tar)
        #expect(meta.fileCount == 1)

        let extracted = try await engine.extract(
            url: tarURL,
            toParent: destDir,
            expectedEntries: meta.entries
        ) { _, _ in }
        #expect(extracted.outputURL.lastPathComponent == "TarFolder")
        #expect(extracted.itemCount == 1)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}
