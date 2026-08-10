import CryptoKit
import Foundation

enum ACEAudioPlacementContract {
    static let handoffSchemaVersion = "music_studio_ace_logic_handoff/v1"
    static let planSchemaVersion = "music_studio_logic_placement_plan/v1"
    static let receiptSchemaVersion = "logic_ace_audio_placement_receipt/v1"
    static let disposableProjectAuthority = "disposable_copy"
    static let defaultBeatsPerBar = 4
    static let defaultRollbackStrategy = "remove_created_region_and_empty_track"
    static let importStageUI = "ui_import"
    static let importStageTagging = "tagging"
    static let importStageReadback = "readback"
    static let allowedRoles: Set<String> = [
        "accompaniment",
        "bass_support",
        "counterline",
        "texture",
        "pad",
        "motif",
        "other",
    ]
    static let allowedAudioFormats: Set<String> = ["wav", "aiff", "aif", "mp3", "flac", "m4a", "ogg"]
}

enum ACEAssetRegionIdentityContract {
    static let schemaVersion = "logic_asset_region_identity/v1"
    static let identityKind = "project_tagged_track_native_source_basename_keeper_digest"
    static let keeperDigestReceiptSchemaVersion = "logic_keeper_digest_receipt/v1"
}

struct ACEPlacementIssue: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var path: String?

    init(code: String, message: String, path: String? = nil) {
        self.code = code
        self.message = message
        self.path = path
    }
}

struct DisposableProjectBinding: Codable, Equatable, Sendable {
    var bindingID: String
    var path: String
    var projectSHA256: String
    var authority: String
    var issuedAt: Date
    var expiresAt: Date
    var originalProjectPath: String?
    var originalProjectPreserved: Bool

    enum CodingKeys: String, CodingKey {
        case bindingID = "binding_id"
        case path
        case projectSHA256 = "project_sha256"
        case authority
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case originalProjectPath = "original_project_path"
        case originalProjectPreserved = "original_project_preserved"
    }

    func isExpired(at now: Date) -> Bool {
        expiresAt <= now
    }
}

struct ACEAudioSource: Codable, Equatable, Sendable {
    var assetID: String
    var path: String
    var sha256: String
    var format: String

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case path
        case sha256
        case format
    }

    var nativeSourceBasename: String {
        URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
    }
}

/// A separately issued and re-verified receipt for the immutable keeper source.
/// The native Logic region name is derived from this source basename and is never
/// used as a place to write operation metadata.
struct ACEKeeperDigestReceipt: Codable, Equatable, Sendable {
    var schemaVersion: String
    var receiptID: String
    var status: String
    var path: String
    var nativeSourceBasename: String
    var sha256: String
    var verifiedAt: Date
    var verifiedBy: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case receiptID = "receipt_id"
        case status
        case path
        case nativeSourceBasename = "native_source_basename"
        case sha256
        case verifiedAt = "verified_at"
        case verifiedBy = "verified_by"
    }
}

/// Stable identity for an imported asset region. Logic exposes only a native
/// region basename, so the identity binds that exact name to the unique tagged
/// parent track, stable project path, and an independently verified keeper digest.
struct ACEAssetRegionIdentity: Codable, Equatable, Sendable {
    var schemaVersion: String
    var stableID: String
    var projectPath: String
    var enclosingTrackID: String
    var enclosingTrackTag: String
    var nativeSourceBasename: String
    var keeperSHA256: String
    var keeperDigestReceiptID: String
    var observedRegionName: String
    var identityKind: String
    var verified: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case stableID = "stable_id"
        case projectPath = "project_path"
        case enclosingTrackID = "enclosing_track_id"
        case enclosingTrackTag = "enclosing_track_tag"
        case nativeSourceBasename = "native_source_basename"
        case keeperSHA256 = "keeper_sha256"
        case keeperDigestReceiptID = "keeper_digest_receipt_id"
        case observedRegionName = "observed_region_name"
        case identityKind = "identity_kind"
        case verified
    }
}

struct ACEPlacementCoordinates: Codable, Equatable, Sendable {
    var bar: Int
    var beat: Double
    var tick: Int
    var durationBeats: Double
    var beatsPerBar: Int

    enum CodingKeys: String, CodingKey {
        case bar
        case beat
        case tick
        case durationBeats = "duration_beats"
        case beatsPerBar = "beats_per_bar"
    }
}

struct ACEAudioPlacementPlan: Codable, Equatable, Sendable {
    var schemaVersion: String
    var planID: String
    var operationID: String
    var roleID: String
    var roleDescription: String
    var claimBoundary: String
    var asset: ACEAudioSource
    var targetProjectPath: String
    var targetProjectSHA256: String
    var bindingID: String
    var trackPolicy: String
    var trackName: String
    var trackTag: String
    var regionTag: String
    var placement: ACEPlacementCoordinates
    var tempoMode: String
    var automaticTimeStretch: Bool
    var gainDB: Double
    var fadeInSeconds: Double
    var fadeOutSeconds: Double
    var collisionMode: String
    var existingContentAction: String
    var rollbackStrategy: String
    var rollbackRequired: Bool
    var rollbackReceiptRequired: Bool
    var keeperDigestReceipt: ACEKeeperDigestReceipt?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case planID = "plan_id"
        case operationID = "operation_id"
        case roleID = "role_id"
        case roleDescription = "role_description"
        case claimBoundary = "claim_boundary"
        case asset
        case targetProjectPath = "target_project_path"
        case targetProjectSHA256 = "target_project_sha256"
        case bindingID = "binding_id"
        case trackPolicy = "track_policy"
        case trackName = "track_name"
        case trackTag = "track_tag"
        case regionTag = "region_tag"
        case placement
        case tempoMode = "tempo_mode"
        case automaticTimeStretch = "automatic_time_stretch"
        case gainDB = "gain_db"
        case fadeInSeconds = "fade_in_seconds"
        case fadeOutSeconds = "fade_out_seconds"
        case collisionMode = "collision_mode"
        case existingContentAction = "existing_content_action"
        case rollbackStrategy = "rollback_strategy"
        case rollbackRequired = "rollback_required"
        case rollbackReceiptRequired = "rollback_receipt_required"
        case keeperDigestReceipt = "keeper_digest_receipt"
    }
}

struct ACEPlacementAuthorization: Codable, Equatable, Sendable {
    var required: Bool
    var status: String
    var confirmedBy: String?
    var confirmedAt: Date?
    var confirmationID: String?

    enum CodingKeys: String, CodingKey {
        case required
        case status
        case confirmedBy = "confirmed_by"
        case confirmedAt = "confirmed_at"
        case confirmationID = "confirmation_id"
    }

    static let pending = ACEPlacementAuthorization(
        required: true,
        status: "pending",
        confirmedBy: nil,
        confirmedAt: nil,
        confirmationID: nil
    )
}

struct ACEPlacementDispatchReceipt: Codable, Equatable, Sendable {
    var status: String
    var method: String?
    var receiptID: String?
    var dispatchedAt: Date?
    var sourceSHA256: String?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case status
        case method
        case receiptID = "receipt_id"
        case dispatchedAt = "dispatched_at"
        case sourceSHA256 = "source_sha256"
        case message
    }
}

/// One bounded phase of the ACE import pipeline.  A stage receipt deliberately
/// separates transport truth (`status`) from mutation truth (`outcome`): a
/// timeout after UI input has started is `unknown`, never a guessed failure or
/// success.
struct ACEPlacementStageReceipt: Codable, Equatable, Sendable {
    var stage: String
    var status: String
    var outcome: String
    var startedAt: Date?
    var completedAt: Date?
    var elapsedMilliseconds: Int?
    var attempt: Int
    var message: String?

    enum CodingKeys: String, CodingKey {
        case stage
        case status
        case outcome
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case elapsedMilliseconds = "elapsed_ms"
        case attempt
        case message
    }

    static func notStarted(stage: String, message: String) -> ACEPlacementStageReceipt {
        ACEPlacementStageReceipt(
            stage: stage,
            status: "not_started",
            outcome: "not_started",
            startedAt: nil,
            completedAt: nil,
            elapsedMilliseconds: nil,
            attempt: 0,
            message: message
        )
    }
}

struct ACEPlacementReadback: Codable, Equatable, Sendable {
    var status: String
    var verified: Bool
    var reasonCode: String
    var observedAt: Date?
    var projectIdentity: String?
    var projectPath: String?
    var assetSHA256: String?
    var trackID: String?
    var regionID: String?
    var trackName: String?
    var placement: ACEPlacementCoordinates?
    var identityKind: String?
    var evidenceURI: String?
    var assetRegionIdentity: ACEAssetRegionIdentity?

    enum CodingKeys: String, CodingKey {
        case status
        case verified
        case reasonCode = "reason_code"
        case observedAt = "observed_at"
        case projectIdentity = "project_identity"
        case projectPath = "project_path"
        case assetSHA256 = "asset_sha256"
        case trackID = "track_id"
        case regionID = "region_id"
        case trackName = "track_name"
        case placement
        case identityKind = "identity_kind"
        case evidenceURI = "evidence_uri"
        case assetRegionIdentity = "asset_region_identity"
    }

    static func notRequested(reasonCode: String = "not_requested") -> ACEPlacementReadback {
        ACEPlacementReadback(
            status: "not_requested",
            verified: false,
            reasonCode: reasonCode,
            observedAt: nil,
            projectIdentity: nil,
            projectPath: nil,
            assetSHA256: nil,
            trackID: nil,
            regionID: nil,
            trackName: nil,
            placement: nil,
            identityKind: nil,
            evidenceURI: nil,
            assetRegionIdentity: nil
        )
    }
}

struct ACEPlacementRollbackReceipt: Codable, Equatable, Sendable {
    var status: String
    var strategy: String
    var mutation: String
    var verification: String
    var reasonCode: String
    var receiptID: String?
    var startedAt: Date?
    var completedAt: Date?
    var trackID: String?
    var regionID: String?
    var evidenceURI: String?
    var projectPath: String? = nil
    var trackTag: String? = nil
    var nativeSourceBasename: String? = nil
    var keeperSHA256: String? = nil
    var instructions: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case status
        case strategy
        case mutation
        case verification
        case reasonCode = "reason_code"
        case receiptID = "receipt_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case trackID = "track_id"
        case regionID = "region_id"
        case evidenceURI = "evidence_uri"
        case projectPath = "project_path"
        case trackTag = "track_tag"
        case nativeSourceBasename = "native_source_basename"
        case keeperSHA256 = "keeper_sha256"
        case instructions
    }

    static func notRequested(strategy: String) -> ACEPlacementRollbackReceipt {
        ACEPlacementRollbackReceipt(
            status: "not_requested",
            strategy: strategy,
            mutation: "not_started",
            verification: "not_requested",
            reasonCode: "not_requested",
            receiptID: nil,
            startedAt: nil,
            completedAt: nil,
            trackID: nil,
            regionID: nil,
            evidenceURI: nil,
            projectPath: nil,
            trackTag: nil,
            nativeSourceBasename: nil,
            keeperSHA256: nil,
            instructions: nil
        )
    }
}

struct ACEPlacementSnapshot: Codable, Equatable, Sendable {
    var observedAt: Date
    var projectPath: String
    var projectSHA256: String
    var generation: UInt64
    var tracks: [TrackState]
    var regions: [RegionState]

    enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at"
        case projectPath = "project_path"
        case projectSHA256 = "project_sha256"
        case generation
        case tracks
        case regions
    }
}

struct ACEAudioPlacementReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = ACEAudioPlacementContract.receiptSchemaVersion

    var schemaVersion: String
    var receiptVersion: Int
    var receiptID: String
    var operationID: String
    var planID: String
    var phase: String
    var status: String
    var success: Bool
    var issuedAt: Date
    var binding: DisposableProjectBinding?
    var asset: ACEAudioSource?
    var keeperDigestReceipt: ACEKeeperDigestReceipt?
    var plan: ACEAudioPlacementPlan?
    var authorization: ACEPlacementAuthorization
    var dispatch: ACEPlacementDispatchReceipt
    var before: ACEPlacementSnapshot?
    var after: ACEPlacementSnapshot?
    var placementGeometry: ACEAudioDeltaGeometry?
    var stageReceipts: [ACEPlacementStageReceipt]
    var readback: ACEPlacementReadback
    var rollback: ACEPlacementRollbackReceipt
    var validationIssues: [ACEPlacementIssue]
    var error: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case receiptVersion = "receipt_version"
        case receiptID = "receipt_id"
        case operationID = "operation_id"
        case planID = "plan_id"
        case phase
        case status
        case success
        case issuedAt = "issued_at"
        case binding
        case asset
        case keeperDigestReceipt = "keeper_digest_receipt"
        case plan
        case authorization
        case dispatch
        case before
        case after
        case placementGeometry = "placement_geometry"
        case stageReceipts = "stage_receipts"
        case readback
        case rollback
        case validationIssues = "validation_issues"
        case error
    }

    init(
        receiptID: String,
        operationID: String,
        planID: String,
        phase: String,
        status: String,
        success: Bool,
        issuedAt: Date,
        binding: DisposableProjectBinding?,
        asset: ACEAudioSource?,
        keeperDigestReceipt: ACEKeeperDigestReceipt? = nil,
        plan: ACEAudioPlacementPlan?,
        authorization: ACEPlacementAuthorization,
        dispatch: ACEPlacementDispatchReceipt,
        before: ACEPlacementSnapshot? = nil,
        after: ACEPlacementSnapshot? = nil,
        placementGeometry: ACEAudioDeltaGeometry? = nil,
        stageReceipts: [ACEPlacementStageReceipt] = [],
        readback: ACEPlacementReadback = .notRequested(),
        rollback: ACEPlacementRollbackReceipt? = nil,
        validationIssues: [ACEPlacementIssue] = [],
        error: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.receiptVersion = 1
        self.receiptID = receiptID
        self.operationID = operationID
        self.planID = planID
        self.phase = phase
        self.status = status
        self.success = success
        self.issuedAt = issuedAt
        self.binding = binding
        self.asset = asset
        self.keeperDigestReceipt = keeperDigestReceipt ?? plan?.keeperDigestReceipt
        self.plan = plan
        self.authorization = authorization
        self.dispatch = dispatch
        self.before = before
        self.after = after
        self.placementGeometry = placementGeometry
        self.stageReceipts = stageReceipts
        self.readback = readback
        self.rollback = rollback ?? .notRequested(strategy: plan?.rollbackStrategy ?? ACEAudioPlacementContract.defaultRollbackStrategy)
        self.validationIssues = validationIssues
        self.error = error
    }
}

struct ACEAudioPlacementSession: Sendable {
    var plan: ACEAudioPlacementPlan
    var authorization: ACEPlacementAuthorization
    var lastReceipt: ACEAudioPlacementReceipt?
}

enum ACEFileDigestError: Error, LocalizedError, Sendable {
    case missing(String)
    case unreadable(String)
    case unsupported(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let path): return "path does not exist: \(path)"
        case .unreadable(let path): return "path is not readable: \(path)"
        case .unsupported(let path): return "path contains an unsupported filesystem entry: \(path)"
        case .readFailed(let path): return "path could not be read: \(path)"
        }
    }
}

enum ACEFileDigest {
    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func sha256(at path: String) throws -> String {
        let normalized = normalizedPath(path)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: normalized) else {
            throw ACEFileDigestError.missing(normalized)
        }
        guard fileManager.isReadableFile(atPath: normalized) else {
            throw ACEFileDigestError.unreadable(normalized)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: normalized)
        } catch {
            throw ACEFileDigestError.readFailed(normalized)
        }

        switch attributes[.type] as? FileAttributeType {
        case .typeRegular:
            do {
                return hex(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: normalized))))
            } catch {
                throw ACEFileDigestError.readFailed(normalized)
            }
        case .typeDirectory:
            return try directorySHA256(at: URL(fileURLWithPath: normalized))
        case .typeSymbolicLink:
            throw ACEFileDigestError.unsupported(normalized)
        default:
            throw ACEFileDigestError.unsupported(normalized)
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit } && value == value.lowercased()
    }

    private static func directorySHA256(at root: URL) throws -> String {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ACEFileDigestError.readFailed(root.path)
        }

        var entries: [(String, Data)] = []
        for case let url as URL in enumerator {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: url.path)
            } catch {
                throw ACEFileDigestError.readFailed(url.path)
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ACEFileDigestError.unsupported(url.path)
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            do {
                let data = try Data(contentsOf: url)
                entries.append((relative, Data(SHA256.hash(data: data))))
            } catch {
                throw ACEFileDigestError.readFailed(url.path)
            }
        }

        var canonical = Data()
        for (relative, digest) in entries.sorted(by: { $0.0 < $1.0 }) {
            canonical.append(contentsOf: Data(relative.utf8))
            canonical.append(0)
            canonical.append(contentsOf: digest)
            canonical.append(10)
        }
        return hex(SHA256.hash(data: canonical))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension ACEAudioSource {
    static func sourceBasename(for path: String) -> String? {
        let basename = URL(fileURLWithPath: ACEFileDigest.normalizedPath(path))
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return basename.isEmpty ? nil : basename
    }
}

enum ACEAudioPlacementValidator {
    static func validateBinding(
        _ binding: DisposableProjectBinding,
        currentProject: ProjectInfo? = nil,
        cacheGeneration: UInt64 = 0,
        now: Date,
        maximumAge: TimeInterval = ServerConfig.projectAuthorityMaxAge,
        verifyOnDisk: Bool = true
    ) -> [ACEPlacementIssue] {
        var issues: [ACEPlacementIssue] = []
        let normalizedPath = ACEFileDigest.normalizedPath(binding.path)

        if binding.authority != ACEAudioPlacementContract.disposableProjectAuthority {
            issues.append(ACEPlacementIssue(
                code: "logic_target_project_not_disposable",
                message: "target project binding must explicitly declare authority=disposable_copy",
                path: "$.binding.authority"
            ))
        }
        if !binding.originalProjectPreserved {
            issues.append(ACEPlacementIssue(
                code: "logic_original_project_not_preserved",
                message: "original project preservation is required",
                path: "$.binding.original_project_preserved"
            ))
        }
        if let original = binding.originalProjectPath,
           ACEFileDigest.normalizedPath(original) == normalizedPath {
            issues.append(ACEPlacementIssue(
                code: "logic_target_project_is_original",
                message: "disposable target path must differ from the preserved original project path",
                path: "$.binding.path"
            ))
        }
        if binding.bindingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_binding_id_missing", message: "binding_id is required", path: "$.binding.binding_id"))
        }
        if !ACEFileDigest.isSHA256(binding.projectSHA256) {
            issues.append(ACEPlacementIssue(code: "logic_project_digest_invalid", message: "project_sha256 must be a lowercase SHA-256 digest", path: "$.binding.project_sha256"))
        }
        if binding.issuedAt > now {
            issues.append(ACEPlacementIssue(code: "logic_binding_not_yet_valid", message: "project binding is issued in the future", path: "$.binding.issued_at"))
        }
        if binding.expiresAt <= now {
            issues.append(ACEPlacementIssue(code: "logic_binding_expired", message: "disposable-project binding has expired; no mutation started", path: "$.binding.expires_at"))
        }
        if binding.expiresAt <= binding.issuedAt {
            issues.append(ACEPlacementIssue(code: "logic_binding_window_invalid", message: "disposable-project binding must expire after it is issued", path: "$.binding.expires_at"))
        }
        if URL(fileURLWithPath: normalizedPath).pathExtension.lowercased() != "logicx" {
            issues.append(ACEPlacementIssue(code: "logic_target_project_not_logicx", message: "disposable target must be an existing .logicx project path", path: "$.binding.path"))
        }

        if let currentProject {
            let currentPath = currentProject.filePath?.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentPath == nil || currentPath?.isEmpty == true {
                issues.append(ACEPlacementIssue(
                    code: "logic_project_path_unavailable",
                    message: "current Logic readback must contain an observed project file path; the binding cannot supply it",
                    path: "$.current_project.file_path"
                ))
            } else if ACEFileDigest.normalizedPath(currentPath!) != normalizedPath {
                issues.append(ACEPlacementIssue(
                    code: "logic_project_path_mismatch",
                    message: "current Logic project path does not match the disposable binding; no mutation started",
                    path: "$.current_project.file_path"
                ))
            }
            if currentProject.projectIdentity.stability != .stable
                || currentProject.projectIdentity.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append(ACEPlacementIssue(
                    code: "logic_project_identity_unstable",
                    message: "current Logic project identity is not a stable observed file identity; the binding cannot upgrade visible-only or unknown state",
                    path: "$.current_project.project_identity"
                ))
            } else if let identityValue = currentProject.projectIdentity.value,
                      ACEFileDigest.normalizedPath(identityValue) != normalizedPath {
                issues.append(ACEPlacementIssue(
                    code: "logic_project_identity_mismatch",
                    message: "stable current project identity does not match the disposable binding; no mutation started",
                    path: "$.current_project.project_identity"
                ))
            }
            let age = now.timeIntervalSince(currentProject.lastUpdated)
            if currentProject.lastUpdated == .distantPast || age < 0 || age > max(0, maximumAge) {
                issues.append(ACEPlacementIssue(
                    code: "logic_project_stale",
                    message: "current Logic project readback is stale; no mutation started",
                    path: "$.current_project.last_updated"
                ))
            }
            if cacheGeneration == 0 || currentProject.generation == 0 || currentProject.generation != cacheGeneration {
                issues.append(ACEPlacementIssue(
                    code: "logic_project_generation_mismatch",
                    message: "current project generation is not compatible with the cache authority; no mutation started",
                    path: "$.current_project.generation"
                ))
            }
        }

        if verifyOnDisk, issues.first(where: { $0.code == "logic_binding_expired" }) == nil {
            do {
                let actual = try ACEFileDigest.sha256(at: normalizedPath)
                if actual != binding.projectSHA256 {
                    issues.append(ACEPlacementIssue(
                        code: "logic_project_digest_mismatch",
                        message: "disposable project digest does not match the explicit binding; no mutation started",
                        path: "$.binding.project_sha256"
                    ))
                }
            } catch {
                issues.append(ACEPlacementIssue(
                    code: "logic_target_project_unreadable",
                    message: "disposable project could not be read for digest verification; no mutation started",
                    path: "$.binding.path"
                ))
            }
        }
        return issues
    }

    static func validateSource(_ source: ACEAudioSource) -> [ACEPlacementIssue] {
        var issues: [ACEPlacementIssue] = []
        let normalizedPath = ACEFileDigest.normalizedPath(source.path)
        if source.assetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(code: "ace_asset_id_missing", message: "asset_id is required", path: "$.asset.asset_id"))
        }
        if !ACEFileDigest.isSHA256(source.sha256) {
            issues.append(ACEPlacementIssue(code: "ace_asset_digest_invalid", message: "asset sha256 must be a lowercase SHA-256 digest", path: "$.asset.source.sha256"))
        }
        if !ACEAudioPlacementContract.allowedAudioFormats.contains(source.format) {
            issues.append(ACEPlacementIssue(code: "ace_audio_format_invalid", message: "audio source format is outside the supported v1 vocabulary", path: "$.asset.audio.format"))
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: normalizedPath) else {
            issues.append(ACEPlacementIssue(code: "ace_asset_missing", message: "audio source file does not exist; no mutation started", path: "$.asset.source.uri"))
            return issues
        }
        guard fileManager.isReadableFile(atPath: normalizedPath) else {
            issues.append(ACEPlacementIssue(code: "ace_asset_unreadable", message: "audio source file is not readable; no mutation started", path: "$.asset.source.uri"))
            return issues
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: normalizedPath)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                issues.append(ACEPlacementIssue(code: "ace_asset_not_regular", message: "audio source must be a regular file; no mutation started", path: "$.asset.source.uri"))
                return issues
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if size <= 0 {
                issues.append(ACEPlacementIssue(code: "ace_asset_empty", message: "audio source file is empty; no mutation started", path: "$.asset.source.uri"))
                return issues
            }
        } catch {
            issues.append(ACEPlacementIssue(code: "ace_asset_inspection_failed", message: "audio source file could not be inspected; no mutation started", path: "$.asset.source.uri"))
            return issues
        }
        if issues.isEmpty || !issues.contains(where: { $0.code == "ace_asset_digest_invalid" }) {
            do {
                if try ACEFileDigest.sha256(at: normalizedPath) != source.sha256 {
                    issues.append(ACEPlacementIssue(
                        code: "ace_asset_digest_mismatch",
                        message: "audio source digest does not match the explicit ACE asset binding; no mutation started",
                        path: "$.asset.source.sha256"
                    ))
                }
            } catch {
                issues.append(ACEPlacementIssue(code: "ace_asset_digest_unavailable", message: "audio source digest could not be read; no mutation started", path: "$.asset.source.sha256"))
            }
        }
        return issues
    }

    static func validateKeeperDigestReceipt(
        _ receipt: ACEKeeperDigestReceipt?,
        source: ACEAudioSource,
        verifyOnDisk: Bool = true
    ) -> [ACEPlacementIssue] {
        guard let receipt else {
            return [ACEPlacementIssue(
                code: "ace_keeper_digest_receipt_missing",
                message: "a separately verified keeper digest receipt is required; no mutation started",
                path: "$.asset.keeper_digest_receipt"
            )]
        }

        var issues: [ACEPlacementIssue] = []
        if receipt.schemaVersion != ACEAssetRegionIdentityContract.keeperDigestReceiptSchemaVersion {
            issues.append(ACEPlacementIssue(
                code: "ace_keeper_digest_receipt_incompatible",
                message: "keeper digest receipt is outside the supported v1 boundary",
                path: "$.asset.keeper_digest_receipt.schema_version"
            ))
        }
        if receipt.receiptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(
                code: "ace_keeper_digest_receipt_id_missing",
                message: "keeper digest receipt_id is required",
                path: "$.asset.keeper_digest_receipt.receipt_id"
            ))
        }
        if receipt.status != "verified" {
            issues.append(ACEPlacementIssue(
                code: "ace_keeper_digest_receipt_unverified",
                message: "keeper digest receipt must have status=verified",
                path: "$.asset.keeper_digest_receipt.status"
            ))
        }
        if ACEFileDigest.normalizedPath(receipt.path) != ACEFileDigest.normalizedPath(source.path) {
            issues.append(ACEPlacementIssue(
                code: "ace_keeper_digest_receipt_path_mismatch",
                message: "keeper digest receipt path does not match the exact source path",
                path: "$.asset.keeper_digest_receipt.path"
            ))
        }
        if !ACEFileDigest.isSHA256(receipt.sha256) {
            issues.append(ACEPlacementIssue(
                code: "ace_keeper_digest_receipt_digest_invalid",
                message: "keeper digest receipt sha256 must be a lowercase SHA-256 digest",
                path: "$.asset.keeper_digest_receipt.sha256"
            ))
        } else if receipt.sha256 != source.sha256 {
            issues.append(ACEPlacementIssue(
                code: "ace_keeper_digest_receipt_digest_mismatch",
                message: "keeper digest receipt does not bind the exact source digest",
                path: "$.asset.keeper_digest_receipt.sha256"
            ))
        }
        let expectedBasename = ACEAudioSource.sourceBasename(for: source.path)
        if expectedBasename == nil || receipt.nativeSourceBasename != expectedBasename {
            issues.append(ACEPlacementIssue(
                code: "ace_keeper_digest_receipt_basename_mismatch",
                message: "keeper digest receipt must carry the exact native source basename",
                path: "$.asset.keeper_digest_receipt.native_source_basename"
            ))
        }
        if receipt.verifiedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(
                code: "ace_keeper_digest_receipt_verifier_missing",
                message: "keeper digest receipt must identify its verifier",
                path: "$.asset.keeper_digest_receipt.verified_by"
            ))
        }

        if verifyOnDisk && issues.isEmpty {
            do {
                let actual = try ACEFileDigest.sha256(at: source.path)
                if actual != receipt.sha256 {
                    issues.append(ACEPlacementIssue(
                        code: "ace_keeper_digest_receipt_drift",
                        message: "keeper digest changed after the separate receipt was issued; no mutation started",
                        path: "$.asset.keeper_digest_receipt.sha256"
                    ))
                }
            } catch {
                issues.append(ACEPlacementIssue(
                    code: "ace_keeper_digest_receipt_reverification_unavailable",
                    message: "keeper digest could not be independently re-verified; no mutation started",
                    path: "$.asset.keeper_digest_receipt.path"
                ))
            }
        }
        return issues
    }

    static func validatePlan(_ plan: ACEAudioPlacementPlan, binding: DisposableProjectBinding) -> [ACEPlacementIssue] {
        var issues: [ACEPlacementIssue] = []
        if plan.schemaVersion != ACEAudioPlacementContract.planSchemaVersion {
            issues.append(ACEPlacementIssue(code: "ace_handoff_incompatible", message: "placement plan is outside the supported v1 boundary", path: "$.placement_plan.schema_version"))
        }
        if plan.planID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_plan_id_missing", message: "plan_id is required", path: "$.placement_plan.plan_id"))
        }
        if plan.operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_operation_id_missing", message: "operation_id is required", path: "$.operation.operation_id"))
        }
        if !ACEAudioPlacementContract.allowedRoles.contains(plan.roleID) {
            issues.append(ACEPlacementIssue(code: "logic_role_missing_or_unknown", message: "role_id must use the canonical v1 role vocabulary", path: "$.placement_plan.role.role_id"))
        }
        if plan.roleDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plan.claimBoundary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_role_claim_missing", message: "role description and claim boundary are required", path: "$.placement_plan.role"))
        }
        if plan.bindingID != binding.bindingID || ACEFileDigest.normalizedPath(plan.targetProjectPath) != ACEFileDigest.normalizedPath(binding.path) || plan.targetProjectSHA256 != binding.projectSHA256 {
            issues.append(ACEPlacementIssue(code: "logic_target_binding_mismatch", message: "placement plan is not bound to the active disposable project path and digest", path: "$.placement_plan.target_project"))
        }
        if plan.trackPolicy != "create_new_track" {
            issues.append(ACEPlacementIssue(code: "logic_existing_track_target_rejected", message: "P4A accepts only a uniquely tagged new audio track; existing track targets are rejected", path: "$.placement_plan.track.policy"))
        }
        if plan.trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plan.trackTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plan.regionTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_track_tag_missing", message: "new-track and region tags are required for unique readback and rollback", path: "$.placement_plan.track"))
        }
        if plan.placement.bar < 1
            || !plan.placement.beat.isFinite
            || plan.placement.beat < 1
            || plan.placement.beat > Double(plan.placement.beatsPerBar)
            || plan.placement.tick < 0
            || !plan.placement.durationBeats.isFinite
            || plan.placement.durationBeats <= 0 {
            issues.append(ACEPlacementIssue(code: "logic_placement_invalid", message: "placement must use a positive in-meter bar/beat start and duration", path: "$.placement_plan.placement"))
        }
        if plan.placement.beatsPerBar < 1 || plan.placement.beatsPerBar > 32 {
            issues.append(ACEPlacementIssue(code: "logic_meter_invalid", message: "beats_per_bar must be between 1 and 32", path: "$.placement_plan.placement.grid.beats_per_bar"))
        }
        if plan.automaticTimeStretch {
            issues.append(ACEPlacementIssue(code: "logic_automatic_stretch_not_authorized", message: "automatic time stretch is forbidden in P4A", path: "$.placement_plan.tempo_policy.automatic_time_stretch"))
        }
        if plan.tempoMode != "preserve_project_tempo" && plan.tempoMode != "preserve_asset_tempo" && plan.tempoMode != "explicit_project_tempo" {
            issues.append(ACEPlacementIssue(code: "logic_tempo_policy_invalid", message: "tempo mode is outside the supported v1 vocabulary", path: "$.placement_plan.tempo_policy.mode"))
        }
        if !plan.gainDB.isFinite || !plan.fadeInSeconds.isFinite || !plan.fadeOutSeconds.isFinite
            || plan.gainDB < -60 || plan.gainDB > 12 || plan.fadeInSeconds < 0 || plan.fadeOutSeconds < 0 {
            issues.append(ACEPlacementIssue(code: "logic_mix_invalid", message: "gain and fades are outside the bounded placement range", path: "$.placement_plan.mix"))
        }
        if (plan.collisionMode != "reject_if_collision" && plan.collisionMode != "append_on_new_track")
            || (plan.existingContentAction != "reject" && plan.existingContentAction != "leave_unchanged") {
            issues.append(ACEPlacementIssue(code: "logic_destructive_collision", message: "existing Logic content must remain unchanged; collision policy must reject", path: "$.placement_plan.collision_policy"))
        }
        if !plan.rollbackRequired || !plan.rollbackReceiptRequired || plan.rollbackStrategy != "remove_created_region" && plan.rollbackStrategy != "remove_created_region_and_empty_track" {
            issues.append(ACEPlacementIssue(code: "logic_rollback_missing", message: "placement requires a bounded rollback strategy and rollback receipt", path: "$.placement_plan.safety.rollback"))
        }
        return issues + validateSource(plan.asset) + validateKeeperDigestReceipt(plan.keeperDigestReceipt, source: plan.asset)
    }

    static func makeTrackTag(planID: String, assetSHA256: String) -> String {
        "ACE-P4A-\(sanitize(planID))-AUDIO-\(assetSHA256.prefix(12))"
    }

    static func makeRegionTag(operationID: String, assetSHA256: String) -> String {
        "ACE-P4A-REGION-\(sanitize(operationID))-\(assetSHA256)"
    }

    private static func sanitize(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_" {
                return Character(String(scalar))
            }
            return "-"
        }
        let result = String(scalars)
        return result.isEmpty ? "operation" : result
    }
}
