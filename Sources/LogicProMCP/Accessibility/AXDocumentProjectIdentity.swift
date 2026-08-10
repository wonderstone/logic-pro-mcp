import Foundation

/// A project identity observed from the front Logic Pro window's AXDocument.
struct ResolvedAXDocument: Sendable, Equatable {
    let path: String
    let digest: String

    var projectIdentity: ProjectIdentity {
        ProjectIdentity.stable(path: path, source: "ax_document", digest: digest)
    }
}

/// Resolves AXDocument values without allowing a title or an unverified path to
/// become stable project authority.
enum AXDocumentProjectResolver {
    static func resolve(
        document: String?,
        windowTitle: String? = nil,
        fileManager: FileManager = .default
    ) -> ResolvedAXDocument? {
        guard let path = normalizedPath(from: document) else { return nil }
        if let windowTitle,
           !windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !titleMatchesProjectPath(windowTitle, path: path) {
            return nil
        }
        guard fileManager.fileExists(atPath: path),
              fileManager.isReadableFile(atPath: path) else {
            return nil
        }

        do {
            let digest = try ACEFileDigest.sha256(at: path)
            guard ACEFileDigest.isSHA256(digest) else { return nil }
            return ResolvedAXDocument(path: path, digest: digest)
        } catch {
            return nil
        }
    }

    /// Resolve the one document candidate belonging to a front window. More
    /// than one candidate is ambiguous and must not become stable identity.
    static func resolve(
        documentCandidates: [String?],
        windowTitle: String? = nil,
        fileManager: FileManager = .default
    ) -> ResolvedAXDocument? {
        let candidates = documentCandidates.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard candidates.count == 1 else { return nil }
        return resolve(document: candidates[0], windowTitle: windowTitle, fileManager: fileManager)
    }

    static func normalizedPath(from document: String?) -> String? {
        guard let rawDocument = document?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDocument.isEmpty,
              hasValidPercentEscapes(rawDocument),
              let url = URL(string: rawDocument),
              url.scheme?.caseInsensitiveCompare("file") == .orderedSame,
              url.host == nil || url.host?.caseInsensitiveCompare("localhost") == .orderedSame,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }

        let decodedPath = url.path
        guard !decodedPath.isEmpty,
              decodedPath.hasPrefix("/") else {
            return nil
        }

        let normalized = URL(fileURLWithPath: decodedPath).standardizedFileURL.path
        guard URL(fileURLWithPath: normalized).pathExtension.caseInsensitiveCompare("logicx") == .orderedSame else {
            return nil
        }
        return normalized
    }

    static func titleMatchesProjectPath(_ rawTitle: String, path: String) -> Bool {
        let expected = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return false }

        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        while title.first == "*" {
            title.removeFirst()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for suffix in [" - Tracks", " - Track", " - Piano Roll", " - Mixer", " - Event List"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
            break
        }

        let parts = title.components(separatedBy: " - ")
        if parts.count >= 2, parts[0].lowercased().hasSuffix(".logicx") {
            title = parts[1]
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.caseInsensitiveCompare(expected) == .orderedSame
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        for index in bytes.indices where bytes[index] == 0x25 {
            guard bytes.index(after: index) < bytes.endIndex,
                  bytes.index(index, offsetBy: 2) < bytes.endIndex,
                  isHex(bytes[bytes.index(after: index)]),
                  isHex(bytes[bytes.index(index, offsetBy: 2)]) else {
                return false
            }
        }
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x46)
            || (byte >= 0x61 && byte <= 0x66)
    }
}
