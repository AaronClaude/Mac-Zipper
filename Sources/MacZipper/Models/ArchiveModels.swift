import Foundation

enum ArchiveFormat: String, Sendable, CaseIterable {
    case zip
    case rar
    case sevenZip = "7z"
    case tar

    var label: String {
        switch self {
        case .zip: return "ZIP"
        case .rar: return "RAR"
        case .sevenZip: return "7Z"
        case .tar: return "TAR"
        }
    }

    static func detect(from url: URL) -> ArchiveFormat? {
        let lowerName = url.lastPathComponent.lowercased()
        if lowerName.hasSuffix(".tar.gz") || lowerName.hasSuffix(".tgz") ||
           lowerName.hasSuffix(".tar.bz2") || lowerName.hasSuffix(".tbz2") ||
           lowerName.hasSuffix(".tar.xz") || lowerName.hasSuffix(".txz") ||
           lowerName.hasSuffix(".tar") {
            return .tar
        }

        switch url.pathExtension.lowercased() {
        case "zip":
            return .zip
        case "rar":
            return .rar
        case "7z":
            return .sevenZip
        default:
            return nil
        }
    }
}

enum ConflictPolicy: String, Sendable, CaseIterable {
    case rename
    case replace

    var label: String {
        switch self {
        case .rename: return "Keep Both (Rename)"
        case .replace: return "Replace Existing"
        }
    }
}

struct ArchiveEntry: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let size: Int64
    let isDirectory: Bool

    var name: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }
}

struct ArchiveMetadata: Sendable {
    let url: URL
    let format: ArchiveFormat
    let compressedSize: Int64
    let entries: [ArchiveEntry]
    let isEncrypted: Bool

    var fileCount: Int {
        entries.filter { !$0.isDirectory }.count
    }

    var totalUncompressedSize: Int64 {
        entries.reduce(0) { $0 + $1.size }
    }
}

enum ExtractionState: Equatable, Sendable {
    case idle
    case inspecting(URL)
    case ready
    case extracting(progress: Double?, status: String)
    case needsPassword(message: String?)
    case completed(outputURL: URL, itemCount: Int)
    case failed(message: String, canInstallUnar: Bool = false)
}

enum RarBackend: String, Sendable {
    case unar
    case unrar
    case sevenZip = "7zz"
    case bsdtar

    var displayName: String {
        switch self {
        case .unar: return "unar"
        case .unrar: return "unrar"
        case .sevenZip: return "7zz"
        case .bsdtar: return "bsdtar (built-in)"
        }
    }

    var isFullRarSupport: Bool {
        self != .bsdtar
    }
}

struct BackendStatus: Sendable {
    let zipEngine: String
    let rarBackend: RarBackend
}
