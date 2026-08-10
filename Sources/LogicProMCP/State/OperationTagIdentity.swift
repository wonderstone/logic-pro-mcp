import Foundation

/// Deterministic identity derived only from a stable project identity and an
/// explicit operation tag. AX element order, runtime identifiers, and frames
/// are deliberately excluded because they are not stable mutation keys.
enum OperationTagIdentity {
    static let prefix = "ACE-P4A-"

    static func operationTag(in name: String) -> String? {
        let candidates = name.split { character in
            !(character.isLetter || character.isNumber || character == "-")
        }
        return candidates
            .map(String.init)
            .first { candidate in
                candidate.hasPrefix(prefix) && candidate.count > prefix.count
            }
    }

    static func trackID(projectIdentity: ProjectIdentity, operationTag: String) -> String? {
        guard isValidOperationTag(operationTag),
              let projectComponent = projectComponent(projectIdentity) else {
            return nil
        }
        return [
            "logic.project-bound.track.v1",
            projectComponent,
            component(operationTag),
        ].joined(separator: ".")
    }

    static func regionID(
        projectIdentity: ProjectIdentity,
        trackOperationTag: String,
        regionOperationTag: String
    ) -> String? {
        guard let trackID = trackID(projectIdentity: projectIdentity, operationTag: trackOperationTag),
              isValidOperationTag(regionOperationTag) else {
            return nil
        }
        return [
            "logic.project-bound.region.v1",
            component(trackID),
            component(regionOperationTag),
        ].joined(separator: ".")
    }

    static func assetRegionID(
        projectIdentity: ProjectIdentity,
        trackOperationTag: String,
        nativeSourceBasename: String,
        keeperSHA256: String
    ) -> String? {
        guard let trackID = trackID(projectIdentity: projectIdentity, operationTag: trackOperationTag),
              !nativeSourceBasename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ACEFileDigest.isSHA256(keeperSHA256) else {
            return nil
        }
        return [
            "logic.project-bound.asset-region.v1",
            component(trackID),
            component(nativeSourceBasename),
            component(keeperSHA256),
        ].joined(separator: ".")
    }

    private static func isValidOperationTag(_ tag: String) -> Bool {
        tag.hasPrefix(prefix)
            && tag.count > prefix.count
            && tag.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private static func projectComponent(_ projectIdentity: ProjectIdentity) -> String? {
        guard projectIdentity.canAuthorizeMutation,
              let value = projectIdentity.value else { return nil }
        let path = URL(fileURLWithPath: value).standardizedFileURL.path
        guard !path.isEmpty else { return nil }
        return component(path)
    }

    private static func component(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
