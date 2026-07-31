//
//  ICloudSetupDiagnostics.swift
//  EncameraCore
//
//  A NON-HALTING diagnostic sweep of everything that has to be true for the app
//  to save media to iCloud, driven by the `ICloudDiagnosticsView` workbench
//  (behind the `iCloudDiagnostics` feature toggle).
//
//  Sibling to `CloudKitFlightCheck`, with the opposite contract — and that
//  difference is the whole point:
//
//    - `CloudKitFlightCheck` is a *proof*: ordered steps, STOPS at the first
//      failure. Right for "did my change work", wrong for "why is this user's
//      phone broken", because the first failure hides every signal after it.
//    - This runs EVERY probe regardless of earlier failures and reports the whole
//      picture at once, grouped into sections, so one run on a misconfigured
//      handset yields the complete evidence set.
//
//  It is deliberately written at the RAW CloudKit layer (CKRecord/CKAsset saves
//  straight to the private DB) rather than through `CloudKitFileAccess`. The app's
//  own layers map and swallow CKErrors into domain errors; for diagnosis we want
//  the untranslated `CKError.Code`, `retryAfterSeconds` and `serverErrorDescription`,
//  because those are exactly the values a user-facing preflight check must branch on.
//
//  Every probe carries a STABLE `id` (e.g. `ck.accountStatus`). Those ids are the
//  intended contract: a runtime preflight check, and the UI-test page object,
//  both key on them rather than on rendered copy.
//
//  Privacy: no probe reads or writes user content. The write probes upload a 4 KB
//  synthetic payload under `Diag-` record names in the app's own zone and delete
//  it again. Account identity is reported only as a truncated SHA-256 fingerprint
//  and CloudKit's own opaque user-record name — never a raw token or an email.
//

import Foundation
import CloudKit
import CryptoKit
import Network
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Report model

/// The outcome of a single probe.
public enum ICloudDiagnosticOutcome: String, Equatable, Sendable {
    /// The condition this probe tests is satisfied.
    case pass
    /// Satisfied, but with a caveat that could explain degraded behaviour
    /// (e.g. connected only over a Low Data Mode link).
    case warn
    /// Not satisfied. Saving to iCloud cannot work while this is true.
    case fail
    /// Informational only — reports state, can never be "wrong" (e.g. how many
    /// records already exist). Kept distinct so the verdict is never skewed by
    /// something that was only ever context.
    case info
    /// Not evaluated because a prerequisite failed. Distinct from `fail` so a
    /// report never implies more broken things than it actually observed.
    case skipped
    /// Declared but not yet run (the workbench renders these as empty rows).
    case pending
}

/// The groups the workbench renders. Ordered causally: a failure high in this
/// list explains failures below it.
public enum ICloudDiagnosticSection: String, CaseIterable, Sendable {
    case build = "Device & Build"
    case network = "Network"
    case account = "iCloud Account"
    case appConfig = "App Configuration"
    case container = "CloudKit Container"
    case writePath = "Write Path"
}

/// The static description of a probe — declared up front so the workbench can
/// render the full checklist before a run starts, and so the id/title/section
/// triple has exactly one definition.
public struct ICloudDiagnosticDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let section: ICloudDiagnosticSection
}

/// One diagnostic signal's result.
public struct ICloudDiagnosticProbe: Equatable, Sendable {
    /// Stable machine key — the contract preflight checks and tests branch on.
    public let id: String
    public let title: String
    public let section: ICloudDiagnosticSection
    public let outcome: ICloudDiagnosticOutcome
    /// One line, safe to render in the checklist.
    public let summary: String
    /// Verbose evidence: raw error codes, userInfo, identifiers.
    public let detail: String

    public init(id: String,
                title: String,
                section: ICloudDiagnosticSection,
                outcome: ICloudDiagnosticOutcome,
                summary: String,
                detail: String = "") {
        self.id = id
        self.title = title
        self.section = section
        self.outcome = outcome
        self.summary = summary
        self.detail = detail
    }
}

/// The full sweep result.
public struct ICloudDiagnosticsReport: Sendable {
    public let probes: [ICloudDiagnosticProbe]

    public init(probes: [ICloudDiagnosticProbe]) {
        self.probes = probes
    }

    public var failures: [ICloudDiagnosticProbe] { probes.filter { $0.outcome == .fail } }
    public var warnings: [ICloudDiagnosticProbe] { probes.filter { $0.outcome == .warn } }

    /// Whether the device can, right now, save media to iCloud.
    public var canSaveToICloud: Bool { failures.isEmpty }

    /// The probe a user-facing message should be built from: the FIRST failure in
    /// probe order. Order is causal (identity → account → container → schema →
    /// write), so the earliest failure is the root cause and the rest is fallout.
    public var rootCause: ICloudDiagnosticProbe? { failures.first }

    /// Compact single-line form for the UI-test accessibility marker:
    /// `complete:ok=<n>/<total>:fail=<id|id>:root=<id — summary>`
    public var markerText: String {
        let considered = probes.filter { $0.outcome != .info && $0.outcome != .pending }
        let ok = considered.filter { $0.outcome == .pass || $0.outcome == .warn || $0.outcome == .skipped }.count
        let failedIDs = failures.map(\.id).joined(separator: "|")
        let root = rootCause.map { "\($0.id) — \($0.summary)" } ?? ""
        return "complete:ok=\(ok)/\(considered.count):fail=\(failedIDs):root=\(root)"
    }

    /// Full multi-line report — written to the debug log, shown behind "Copy
    /// report" in the workbench, and attached verbatim to the xcresult bundle by
    /// the device suite.
    public var fullText: String {
        var lines: [String] = ["===== iCloud Setup Diagnostics ====="]
        for section in ICloudDiagnosticSection.allCases {
            let sectionProbes = probes.filter { $0.section == section }
            guard !sectionProbes.isEmpty else { continue }
            lines.append("")
            lines.append("## \(section.rawValue)")
            for probe in sectionProbes {
                lines.append("[\(probe.outcome.reportMark)] \(probe.id) — \(probe.title)")
                lines.append("       \(probe.summary)")
                if !probe.detail.isEmpty {
                    for detailLine in probe.detail.split(separator: "\n", omittingEmptySubsequences: false) {
                        lines.append("       | \(detailLine)")
                    }
                }
            }
        }
        lines.append("")
        lines.append("-----------------------------------")
        lines.append("VERDICT: \(canSaveToICloud ? "iCloud saves should work" : "iCloud saves are BROKEN")")
        if let root = rootCause {
            lines.append("ROOT CAUSE: \(root.id) — \(root.summary)")
        }
        for warning in warnings {
            lines.append("WARNING: \(warning.id) — \(warning.summary)")
        }
        lines.append("===================================")
        return lines.joined(separator: "\n")
    }
}

extension ICloudDiagnosticOutcome {
    var reportMark: String {
        switch self {
        case .pass:    return "PASS"
        case .warn:    return "WARN"
        case .fail:    return "FAIL"
        case .info:    return "INFO"
        case .skipped: return "SKIP"
        case .pending: return "----"
        }
    }
}

// MARK: - Engine

/// Runs the diagnostic sweep. Construct once per run. Safe on a device with no
/// iCloud account at all, and safe against a real Apple ID — nothing it writes
/// outlives the run.
public final class ICloudSetupDiagnostics: DebugPrintable {

    /// Every probe this engine can emit, in run order. The workbench renders this
    /// as the checklist before a run and fills each row in as results arrive.
    public static let catalog: [ICloudDiagnosticDescriptor] = [
        .init(id: "build.environment",       title: "Build & container identity",         section: .build),
        .init(id: "build.device",            title: "Device & OS state",                  section: .build),

        .init(id: "system.network",          title: "Network path",                       section: .network),

        .init(id: "system.ubiquityToken",    title: "iCloud account signed in",           section: .account),
        .init(id: "ck.accountStatus",        title: "CloudKit account status",            section: .account),
        .init(id: "ck.userRecord",           title: "CloudKit user record",               section: .account),
        .init(id: "drive.ubiquityContainer", title: "iCloud Drive container",             section: .account),

        .init(id: "app.cloudKitToggle",      title: "CloudKit storage feature toggle",    section: .appConfig),
        .init(id: "app.storageAvailability", title: "App's own iCloud availability verdict", section: .appConfig),
        .init(id: "app.encryptionKey",       title: "Encryption key available",           section: .appConfig),
        .init(id: "app.entitlement",         title: "Premium entitlement",                section: .appConfig),
        .init(id: "app.albumInventory",      title: "Local album inventory",              section: .appConfig),

        .init(id: "ck.containerReachable",   title: "Container reachable / entitled",     section: .container),
        .init(id: "ck.zone",                 title: "Record zone present",                section: .container),
        .init(id: "ck.zoneFlag",             title: "Persisted zone-created flag",        section: .container),
        .init(id: "ck.subscription",         title: "Zone push subscription",             section: .container),
        .init(id: "ck.inventory",            title: "Records already in the zone",        section: .container),

        .init(id: "ck.albumWrite",           title: "Write EncAlbum record (schema)",     section: .writePath),
        .init(id: "ck.mediaWrite",           title: "Upload EncMedia record + CKAsset",   section: .writePath),
        .init(id: "ck.readBack",             title: "Read the uploaded asset back",       section: .writePath),
        .init(id: "ck.cleanup",              title: "Remove probe records",               section: .writePath),
    ]

    /// Record names written by this sweep share this prefix, so a probe record
    /// leaked by a crashed run is identifiable and removable later.
    public static let probeRecordPrefix = "Diag-"

    private let container: CKContainer
    private let containerID: String
    private let zoneID: CKRecordZone.ID
    private let keyManager: KeyManager?
    private let albumManager: AlbumManaging?
    private let permissions: PurchasedPermissionManaging?
    private let defaults: UserDefaults

    /// Dependencies are optional so the engine can also run in contexts that have
    /// no key or album manager (e.g. before onboarding). Probes that need one
    /// report `.info` rather than failing when it is absent — a missing collaborator
    /// is a limitation of the caller, never evidence that iCloud is broken.
    public init(keyManager: KeyManager? = nil,
                albumManager: AlbumManaging? = nil,
                permissions: PurchasedPermissionManaging? = nil,
                containerID: String = CloudKitSchema.containerID,
                defaults: UserDefaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard) {
        self.containerID = containerID
        self.container = CKContainer(identifier: containerID)
        self.zoneID = CKRecordZone.ID(zoneName: CloudKitSchema.zoneName)
        self.keyManager = keyManager
        self.albumManager = albumManager
        self.permissions = permissions
        self.defaults = defaults
    }

    /// Runs every probe in catalog order, reporting each result through `onProbe`
    /// as soon as it lands so the workbench fills in live. Never throws; a probe
    /// that blows up is recorded as a failure and the sweep continues.
    @discardableResult
    public func run(onProbe: @MainActor @escaping (ICloudDiagnosticProbe) -> Void = { _ in }) async -> ICloudDiagnosticsReport {
        printDebug("iCloud diagnostics starting — container=\(containerID) zone=\(CloudKitSchema.zoneName)")
        var probes: [ICloudDiagnosticProbe] = []

        /// Records a probe and pushes it to the UI in one step, so no probe can
        /// be added to the report without also being rendered.
        func emit(_ probe: ICloudDiagnosticProbe) async {
            probes.append(probe)
            await onProbe(probe)
        }

        await emit(buildEnvironmentProbe())
        await emit(await deviceStateProbe())
        await emit(networkProbe())

        await emit(ubiquityTokenProbe())

        let account = await accountStatusProbe()
        await emit(account)
        // Everything below needs a usable account. Without one, CloudKit calls all
        // return .notAuthenticated and would report N identical failures — which
        // overstates the number of distinct problems and buries the real one.
        let accountUsable = account.outcome == .pass

        await emit(await userRecordProbe(accountUsable: accountUsable))
        await emit(await ubiquityContainerProbe())

        await emit(cloudKitToggleProbe())
        await emit(storageAvailabilityProbe())
        await emit(encryptionKeyProbe())
        await emit(await entitlementProbe())
        await emit(albumInventoryProbe())

        let reachable = await containerReachabilityProbe(accountUsable: accountUsable)
        await emit(reachable)
        let containerReachable = reachable.outcome == .pass

        // Whether the zone was there BEFORE this sweep touched it. `zoneProbe`
        // heals a missing zone (that is what the app does on first use), so the
        // pre-existing state has to be captured or the flag-mismatch check below
        // can never see the very condition it exists to catch.
        let zoneExistedBefore = (try? await zoneExistsOnServer()) ?? false

        let zone = await zoneProbe(prerequisitesMet: containerReachable)
        await emit(zone)
        let zoneReady = zone.outcome == .pass

        await emit(zoneFlagProbe(zoneExistedBefore: zoneExistedBefore,
                                 containerReachable: containerReachable))
        await emit(await subscriptionProbe(prerequisitesMet: zoneReady))
        await emit(await zoneInventoryProbe(prerequisitesMet: zoneReady))

        // The two writes are the money probes: quota, a disabled per-app iCloud
        // toggle, managed-account restrictions and an undeployed schema only ever
        // surface on an actual save.
        let albumWrite = await albumRecordWriteProbe(prerequisitesMet: zoneReady)
        await emit(albumWrite.probe)

        let mediaWrite = await mediaAssetWriteProbe(prerequisitesMet: zoneReady)
        await emit(mediaWrite.probe)

        await emit(await readBackProbe(recordID: mediaWrite.recordID, expectedBytes: mediaWrite.payload))
        await emit(await cleanupProbe(recordIDs: [mediaWrite.recordID, albumWrite.recordID].compactMap { $0 }))

        let report = ICloudDiagnosticsReport(probes: probes)
        printDebug("\n" + report.fullText)
        return report
    }

    // MARK: - Section: Device & Build

    /// Which container, which CloudKit *environment*, which bundle. A save that
    /// works in Development and fails in Production (undeployed schema) is
    /// indistinguishable from "iCloud is broken" without this line.
    private func buildEnvironmentProbe() -> ICloudDiagnosticProbe {
        let bundleID = Bundle.main.bundleIdentifier ?? "<unknown>"
        let environment = Self.cloudKitEnvironment()
        var detail = """
        bundleID=\(bundleID)
        containerID=\(containerID)
        zone=\(CloudKitSchema.zoneName)
        cloudKitEnvironment=\(environment)
        recordTypes=\(CloudKitSchema.EncAlbum.recordType), \(CloudKitSchema.EncMedia.recordType)
        schemaVersion=\(CloudKitSchema.currentSchemaVersion)
        """
        #if DEBUG
        detail += "\nbuildConfiguration=Debug"
        #else
        detail += "\nbuildConfiguration=Release"
        #endif

        return ICloudDiagnosticProbe(
            id: "build.environment",
            title: "Build & container identity",
            section: .build,
            outcome: .info,
            summary: "\(containerID) — \(environment)",
            detail: detail
        )
    }

    /// Best-effort report of which CloudKit environment this build talks to.
    ///
    /// There is no public runtime API on iOS for reading our own SIGNED
    /// entitlements (`SecTask*` is not in the public iOS SDK), and the signed
    /// entitlement is what CloudKit actually honours. What we CAN read is the
    /// embedded provisioning profile — but its
    /// `com.apple.developer.icloud-container-environment` is usually an ARRAY of
    /// the environments the profile *permits* (typically both), not the one that
    /// was selected. Reading it as a single string and reporting the result as
    /// fact is how this probe originally claimed "Development" for a build whose
    /// signed entitlement said Production.
    ///
    /// So: report exactly what is knowable, and say plainly when it is ambiguous
    /// rather than guessing. `Scripts/icloud-diagnostics-device-test.sh` resolves
    /// the ambiguity from outside the app by running `codesign -d --entitlements`
    /// on the built binary, and `ck.inventory` disambiguates empirically — the two
    /// environments are separate databases with different contents.
    public static func cloudKitEnvironment() -> String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            // No embedded profile means App Store distribution, which is always Production.
            return "Production (no embedded profile — App Store build)"
        }
        // The profile is CMS-signed; the plist sits inside it as plain text.
        guard let raw = String(data: data, encoding: .isoLatin1),
              let start = raw.range(of: "<?xml"),
              let end = raw.range(of: "</plist>") else {
            return "unknown (profile unreadable)"
        }
        let plistText = String(raw[start.lowerBound..<end.upperBound])
        guard let plistData = plistText.data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData,
                                                                     options: [],
                                                                     format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return "unknown (entitlements not in profile)"
        }
        let value = entitlements["com.apple.developer.icloud-container-environment"]
        if let single = value as? String {
            return single
        }
        if let allowed = value as? [String] {
            if allowed.count == 1 { return allowed[0] }
            return "AMBIGUOUS — profile permits \(allowed.joined(separator: " or "))"
                + "; the effective value lives in the signed entitlement, which iOS cannot read at runtime"
        }
        // Absent key on a development profile: Xcode defaults to Development.
        return "Development (no container-environment entitlement in the profile)"
    }

    /// OS-level conditions that throttle or defer CloudKit work without ever
    /// producing an error — the states that make saving look "stuck" rather than
    /// failed.
    private func deviceStateProbe() async -> ICloudDiagnosticProbe {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        #if canImport(UIKit)
        let refreshStatus = await MainActor.run { UIApplication.shared.backgroundRefreshStatus }
        let refreshDescription: String
        switch refreshStatus {
        case .available:   refreshDescription = "available"
        case .denied:      refreshDescription = "denied"
        case .restricted:  refreshDescription = "restricted"
        @unknown default:  refreshDescription = "unknown(\(refreshStatus.rawValue))"
        }
        #else
        let refreshDescription = "n/a"
        #endif

        let freeBytes = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? nil
        let freeDescription = freeBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "unknown"

        let detail = """
        os=\(ProcessInfo.processInfo.operatingSystemVersionString)
        lowPowerMode=\(lowPower)
        backgroundRefresh=\(refreshDescription)
        freeDiskSpace=\(freeDescription)
        """

        // Low Power Mode does not block a foreground save, so this is a warning
        // rather than a failure — but it is the single most common reason an
        // upload "never finishes" while nothing reports an error.
        let outcome: ICloudDiagnosticOutcome = lowPower ? .warn : .info
        let summary = lowPower
            ? "Low Power Mode is ON — background CloudKit work is deferred"
            : "\(ProcessInfo.processInfo.operatingSystemVersionString), \(freeDescription) free"

        return ICloudDiagnosticProbe(id: "build.device",
                                     title: "Device & OS state",
                                     section: .build,
                                     outcome: outcome,
                                     summary: summary,
                                     detail: detail)
    }

    // MARK: - Section: Network

    /// A snapshot of the current path. `isConstrained` is Low Data Mode and
    /// `isExpensive` is cellular/hotspot — both throttle CloudKit asset uploads
    /// hard, and both present as "saving is stuck" rather than as an error.
    private func networkProbe() -> ICloudDiagnosticProbe {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "icloud.diagnostics.path"))
        // currentPath populates once started; give the first update a moment on a
        // cold start rather than reporting a spurious .requiresConnection.
        Thread.sleep(forTimeInterval: 0.3)
        let path = monitor.currentPath
        monitor.cancel()

        var interfaces: [String] = []
        if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
        if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.append("ethernet") }

        let detail = """
        status=\(path.status)
        interfaces=\(interfaces.isEmpty ? "none" : interfaces.joined(separator: ","))
        isExpensive=\(path.isExpensive)
        isConstrained=\(path.isConstrained)
        """

        guard path.status == .satisfied else {
            return ICloudDiagnosticProbe(id: "system.network",
                                         title: "Network path",
                                         section: .network,
                                         outcome: .fail,
                                         summary: "No usable network path (status \(path.status))",
                                         detail: detail)
        }
        if path.isConstrained {
            return ICloudDiagnosticProbe(
                id: "system.network",
                title: "Network path",
                section: .network,
                outcome: .warn,
                summary: "Online but CONSTRAINED (Low Data Mode) — CloudKit uploads are deprioritised",
                detail: detail)
        }
        return ICloudDiagnosticProbe(
            id: "system.network",
            title: "Network path",
            section: .network,
            outcome: .pass,
            summary: "Online over \(interfaces.joined(separator: ","))\(path.isExpensive ? " (expensive link)" : "")",
            detail: detail)
    }

    // MARK: - Section: iCloud Account

    /// `FileManager.ubiquityIdentityToken` — the signal the app CURRENTLY gates
    /// every iCloud storage decision on (`DataStorageAvailabilityUtil`). Reported
    /// separately from `ck.accountStatus` precisely so the workbench can show the
    /// two disagreeing, which is the interesting case.
    private func ubiquityTokenProbe() -> ICloudDiagnosticProbe {
        guard let token = FileManager.default.ubiquityIdentityToken else {
            return ICloudDiagnosticProbe(
                id: "system.ubiquityToken",
                title: "iCloud account signed in",
                section: .account,
                outcome: .fail,
                summary: "No ubiquityIdentityToken — iOS reports no iCloud-capable account",
                detail: "FileManager.default.ubiquityIdentityToken == nil. This is the exact signal "
                    + "DataStorageAvailabilityUtil.isStorageTypeAvailable(.cloudKit) uses, so the app "
                    + "is already hiding iCloud storage on this device.")
        }
        return ICloudDiagnosticProbe(
            id: "system.ubiquityToken",
            title: "iCloud account signed in",
            section: .account,
            outcome: .pass,
            summary: "Signed in — account fingerprint \(Self.fingerprint(of: token))",
            detail: "ubiquityIdentityToken present. The fingerprint is a truncated SHA-256 of the "
                + "archived token: stable for one Apple ID on one device, so two runs (or two "
                + "handsets) can be compared without ever logging the token or an email address.")
    }

    /// Truncated SHA-256 of the archived token — stable and non-reversible.
    public static func fingerprint(of token: any NSCoding & NSCopying & NSObjectProtocol) -> String {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token,
                                                           requiringSecureCoding: false) else {
            return "<unhashable>"
        }
        return String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    private func accountStatusProbe() async -> ICloudDiagnosticProbe {
        func probe(_ outcome: ICloudDiagnosticOutcome, _ summary: String, _ detail: String) -> ICloudDiagnosticProbe {
            ICloudDiagnosticProbe(id: "ck.accountStatus",
                                  title: "CloudKit account status",
                                  section: .account,
                                  outcome: outcome,
                                  summary: summary,
                                  detail: detail)
        }
        do {
            let status = try await container.accountStatus()
            let base = "CKAccountStatus = \(CloudKitFlightCheck.describe(status)) "
                + "(raw \(status.rawValue)) for container \(containerID)"
            switch status {
            case .available:
                return probe(.pass, "available", base)
            case .noAccount:
                return probe(.fail, "noAccount — CloudKit sees no iCloud account for this app",
                             base + "\nNote: iOS also reports .noAccount when the account exists but "
                                 + "iCloud Drive is switched OFF, and when this app's own toggle under "
                                 + "Settings › Apple ID › iCloud › Apps Using iCloud has been turned off.")
            case .restricted:
                return probe(.fail, "restricted — iCloud is blocked by parental controls, MDM, or Screen Time", base)
            case .couldNotDetermine:
                return probe(.fail, "couldNotDetermine — the account state could not be resolved",
                             base + "\nUsually transient (offline, or the account daemon has not settled). "
                                 + "A persistent couldNotDetermine alongside a valid ubiquity token points "
                                 + "at a credential the system wants re-entered.")
            case .temporarilyUnavailable:
                return probe(.fail, "temporarilyUnavailable — the Apple ID needs attention in Settings",
                             base + "\nThis is the state iOS uses when the account needs re-authentication "
                                 + "or a terms-of-service acceptance. The user is 'signed in' as far as the "
                                 + "ubiquity token is concerned, but CloudKit will refuse writes.")
            @unknown default:
                return probe(.fail, "unknown status \(status.rawValue)", base)
            }
        } catch {
            return probe(.fail,
                         "accountStatus() threw: \(Self.shortError(error))",
                         Self.describe(error))
        }
    }

    /// Proves CloudKit can actually identify the signed-in user for THIS container,
    /// and yields a per-container stable user id. Comparing that id across devices
    /// tells you whether two handsets are really on the same Apple ID.
    private func userRecordProbe(accountUsable: Bool) async -> ICloudDiagnosticProbe {
        guard accountUsable else {
            return ICloudDiagnosticProbe(id: "ck.userRecord",
                                         title: "CloudKit user record",
                                         section: .account,
                                         outcome: .skipped,
                                         summary: "Skipped — no usable account",
                                         detail: "")
        }
        do {
            let recordID = try await container.userRecordID()
            return ICloudDiagnosticProbe(
                id: "ck.userRecord",
                title: "CloudKit user record",
                section: .account,
                outcome: .pass,
                summary: "Resolved user record \(recordID.recordName)",
                detail: "The record name is CloudKit's per-container user id: stable for one Apple ID "
                    + "in one container, and different between accounts. Compare it across devices to "
                    + "confirm they really are on the same iCloud account.")
        } catch {
            return ICloudDiagnosticProbe(id: "ck.userRecord",
                                         title: "CloudKit user record",
                                         section: .account,
                                         outcome: .fail,
                                         summary: "Could not resolve the user record: \(Self.shortError(error))",
                                         detail: Self.describe(error))
        }
    }

    /// The legacy iCloud Drive container. Not required for CloudKit saves, but it
    /// is the probe that distinguishes "iCloud Drive is off" from "the account is
    /// gone", and legacy Drive albums depend on it.
    private func ubiquityContainerProbe() async -> ICloudDiagnosticProbe {
        // url(forUbiquityContainerIdentifier:) blocks; never call it on the main thread.
        let url = await Task.detached(priority: .utility) { [containerID] in
            FileManager.default.url(forUbiquityContainerIdentifier: containerID)
        }.value

        guard let url else {
            return ICloudDiagnosticProbe(
                id: "drive.ubiquityContainer",
                title: "iCloud Drive container",
                section: .account,
                outcome: .warn,
                summary: "No ubiquity container URL — iCloud Drive is unavailable to this app",
                detail: "FileManager.url(forUbiquityContainerIdentifier: \(containerID)) returned nil. "
                    + "CloudKit saves do not need this, so it is a warning rather than a failure — but "
                    + "legacy iCloud Drive albums cannot be read while it is nil.")
        }
        return ICloudDiagnosticProbe(id: "drive.ubiquityContainer",
                                     title: "iCloud Drive container",
                                     section: .account,
                                     outcome: .pass,
                                     summary: "Container available",
                                     detail: "path=\(url.path)")
    }

    // MARK: - Section: App Configuration

    /// Reports the effective toggle AND the value a build of this configuration
    /// would use with no override.
    ///
    /// Reporting only the effective value is actively misleading here: a debug
    /// build defaults it ON and a UI test forces it ON, so the probe would say
    /// "ON" on the very device whose release build has it OFF. The build default
    /// is what a shipped app actually does, so it gets stated explicitly and an
    /// explicit override is called out as an override.
    private func cloudKitToggleProbe() -> ICloudDiagnosticProbe {
        let enabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        let hasOverride: Bool = UserDefaultUtils
            .boolNullable(forKey: .featureToggle(feature: .cloudKitStorage)) != nil
        let buildDefault = Feature.cloudKitStorage.defaultValue ?? false

        var detail = """
        effective=\(enabled)
        explicitOverridePresent=\(hasOverride)
        buildDefault=\(buildDefault)
        """
        #if DEBUG
        detail += "\nbuildConfiguration=Debug — cloudKitStorage.defaultValue is true here"
        #else
        detail += "\nbuildConfiguration=Release — cloudKitStorage.defaultValue is nil, so isEnabled() falls back to FALSE"
        #endif
        detail += "\n\nWith this OFF, DataStorageAvailabilityUtil reports .cloudKit unavailable and the "
            + "storage picker never offers iCloud — regardless of account state. iCloud Drive is "
            + "separately and unconditionally deprecated for new albums, so a build with this off has "
            + "NO iCloud destination at all."

        if !enabled {
            return ICloudDiagnosticProbe(
                id: "app.cloudKitToggle",
                title: "CloudKit storage feature toggle",
                section: .appConfig,
                outcome: .fail,
                summary: "cloudKitStorage is OFF — iCloud is not offered as a storage destination",
                detail: detail)
        }
        if !buildDefault && hasOverride {
            return ICloudDiagnosticProbe(
                id: "app.cloudKitToggle",
                title: "CloudKit storage feature toggle",
                section: .appConfig,
                outcome: .warn,
                summary: "ON, but only via an explicit override — a build of this configuration defaults it OFF",
                detail: detail)
        }
        return ICloudDiagnosticProbe(id: "app.cloudKitToggle",
                                     title: "CloudKit storage feature toggle",
                                     section: .appConfig,
                                     outcome: .pass,
                                     summary: "cloudKitStorage is ON (build default)",
                                     detail: detail)
    }

    /// What the app itself currently believes. Reported next to the raw account
    /// signals on purpose: when this says "available" while `ck.accountStatus`
    /// says otherwise, that gap IS the bug — the app offers iCloud and then every
    /// save fails.
    private func storageAvailabilityProbe() -> ICloudDiagnosticProbe {
        let cloudKitAvailable = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .cloudKit)
        let cloudKitOffered = DataStorageAvailabilityUtil.isStorageTypeOfferedForNewAlbums(type: .cloudKit)
        let driveAvailable = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud)

        let detail = """
        isStorageTypeAvailable(.cloudKit)=\(cloudKitAvailable)
        isStorageTypeOfferedForNewAlbums(.cloudKit)=\(cloudKitOffered)
        isStorageTypeAvailable(.icloud/Drive)=\(driveAvailable)

        NOTE: this verdict is derived ONLY from the feature toggle and
        FileManager.ubiquityIdentityToken != nil. It does NOT consult CKAccountStatus,
        iCloud storage quota, or the per-app iCloud switch — so it can report
        'available' on a device that cannot actually save.
        """

        let isAvailable = cloudKitAvailable == .available
        return ICloudDiagnosticProbe(
            id: "app.storageAvailability",
            title: "App's own iCloud availability verdict",
            section: .appConfig,
            outcome: .info,
            summary: isAvailable
                ? "The app currently considers iCloud storage AVAILABLE"
                : "The app currently considers iCloud storage UNAVAILABLE",
            detail: detail)
    }

    private func encryptionKeyProbe() -> ICloudDiagnosticProbe {
        guard let keyManager else {
            return ICloudDiagnosticProbe(id: "app.encryptionKey",
                                         title: "Encryption key available",
                                         section: .appConfig,
                                         outcome: .info,
                                         summary: "Not checked — no key manager supplied to this run",
                                         detail: "")
        }
        guard let key = keyManager.currentKey else {
            return ICloudDiagnosticProbe(
                id: "app.encryptionKey",
                title: "Encryption key available",
                section: .appConfig,
                outcome: .fail,
                summary: "No current key — media cannot be encrypted, so nothing can be uploaded",
                detail: "KeyManager.currentKey == nil. Saves fail before CloudKit is ever reached.")
        }
        return ICloudDiagnosticProbe(id: "app.encryptionKey",
                                     title: "Encryption key available",
                                     section: .appConfig,
                                     outcome: .pass,
                                     summary: "Key '\(key.name)' (\(key.keyBytes.count) bytes)",
                                     detail: "")
    }

    private func entitlementProbe() async -> ICloudDiagnosticProbe {
        guard let permissions else {
            return ICloudDiagnosticProbe(id: "app.entitlement",
                                         title: "Premium entitlement",
                                         section: .appConfig,
                                         outcome: .info,
                                         summary: "Not checked — no permission manager supplied to this run",
                                         detail: "")
        }
        let hasEntitlement = permissions.hasEntitlement
        return ICloudDiagnosticProbe(
            id: "app.entitlement",
            title: "Premium entitlement",
            section: .appConfig,
            outcome: .info,
            summary: hasEntitlement ? "Entitled" : "No active entitlement",
            detail: "PurchasedPermissionManaging.hasEntitlement = \(hasEntitlement). Reported as context: "
                + "import limits are enforced above the storage layer, so this does not by itself "
                + "explain a CloudKit write failure.")
    }

    private func albumInventoryProbe() -> ICloudDiagnosticProbe {
        guard let albumManager else {
            return ICloudDiagnosticProbe(id: "app.albumInventory",
                                         title: "Local album inventory",
                                         section: .appConfig,
                                         outcome: .info,
                                         summary: "Not checked — no album manager supplied to this run",
                                         detail: "")
        }
        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
        var counts: [StorageType: Int] = [:]
        for album in albums {
            counts[album.storageOption, default: 0] += 1
        }
        let breakdown = StorageType.allCases
            .map { "\($0): \(counts[$0] ?? 0)" }
            .joined(separator: ", ")
        return ICloudDiagnosticProbe(id: "app.albumInventory",
                                     title: "Local album inventory",
                                     section: .appConfig,
                                     outcome: .info,
                                     summary: "\(albums.count) album(s) — \(breakdown)",
                                     detail: "Counts every album the app can see, hidden included.")
    }

    // MARK: - Section: CloudKit Container

    private func containerReachabilityProbe(accountUsable: Bool) async -> ICloudDiagnosticProbe {
        guard accountUsable else {
            return ICloudDiagnosticProbe(id: "ck.containerReachable",
                                         title: "Container reachable / entitled",
                                         section: .container,
                                         outcome: .skipped,
                                         summary: "Skipped — no usable account",
                                         detail: "")
        }
        do {
            let zones = try await container.privateCloudDatabase.allRecordZones()
            return ICloudDiagnosticProbe(
                id: "ck.containerReachable",
                title: "Container reachable / entitled",
                section: .container,
                outcome: .pass,
                summary: "Private DB answered — \(zones.count) zone(s)",
                detail: "zones=\(zones.map(\.zoneID.zoneName).joined(separator: ", "))")
        } catch {
            var extra = ""
            if let ckError = error as? CKError,
               ckError.code == .missingEntitlement || ckError.code == .badContainer {
                extra = "\nINTERPRETATION: an app-signing problem, not a user problem — this build's "
                    + "entitlement does not grant \(containerID)."
            }
            return ICloudDiagnosticProbe(id: "ck.containerReachable",
                                         title: "Container reachable / entitled",
                                         section: .container,
                                         outcome: .fail,
                                         summary: "Private DB request failed: \(Self.shortError(error))",
                                         detail: Self.describe(error) + extra)
        }
    }

    private func zoneProbe(prerequisitesMet: Bool) async -> ICloudDiagnosticProbe {
        guard prerequisitesMet else {
            return ICloudDiagnosticProbe(id: "ck.zone",
                                         title: "Record zone present",
                                         section: .container,
                                         outcome: .skipped,
                                         summary: "Skipped — container not reachable",
                                         detail: "")
        }
        do {
            let zones = try await container.privateCloudDatabase.allRecordZones()
            if zones.contains(where: { $0.zoneID.zoneName == CloudKitSchema.zoneName }) {
                return ICloudDiagnosticProbe(id: "ck.zone",
                                             title: "Record zone present",
                                             section: .container,
                                             outcome: .pass,
                                             summary: "\(CloudKitSchema.zoneName) exists",
                                             detail: "")
            }
            // Missing — create it, which is what the app does on first use.
            _ = try await container.privateCloudDatabase.modifyRecordZones(
                saving: [CKRecordZone(zoneName: CloudKitSchema.zoneName)], deleting: [])
            return ICloudDiagnosticProbe(
                id: "ck.zone",
                title: "Record zone present",
                section: .container,
                outcome: .pass,
                summary: "\(CloudKitSchema.zoneName) was missing and has now been created",
                detail: "A zone that had to be created here means this account had never successfully "
                    + "used CloudKit storage in this container before.")
        } catch {
            return ICloudDiagnosticProbe(id: "ck.zone",
                                         title: "Record zone present",
                                         section: .container,
                                         outcome: .fail,
                                         summary: "Zone unavailable and could not be created: \(Self.shortError(error))",
                                         detail: Self.describe(error))
        }
    }

    /// The app skips zone creation entirely when this flag is set
    /// (`CloudKitContainer.ensureZoneExists` returns early on it). So a flag that
    /// is `true` while the zone is ABSENT is a permanent, self-healing-never
    /// failure: the app will never provision the zone, and every subsequent save
    /// fails with `.zoneNotFound` forever. That combination is the single most
    /// important thing this sweep can detect, so it gets its own hard failure
    /// rather than being inferable from two other rows.
    ///
    /// The flag is keyed by container id only — the CloudKit *environment* is not
    /// part of the key, and the container id is identical in Development and
    /// Production. Any path that removes the zone without clearing the flag (a
    /// wipe from another device, an account switch, a server-side reset) lands the
    /// app in exactly this state.
    private func zoneFlagProbe(zoneExistedBefore: Bool, containerReachable: Bool) -> ICloudDiagnosticProbe {
        let key = "cloudkit_zone_created_v1_" + containerID
        let flag = defaults.bool(forKey: key)
        let base = "defaults[\(key)] = \(flag); zone existed before this sweep = \(zoneExistedBefore)"

        // Only meaningful once we know the real server-side state.
        guard containerReachable else {
            return ICloudDiagnosticProbe(
                id: "ck.zoneFlag",
                title: "Persisted zone-created flag",
                section: .container,
                outcome: .skipped,
                summary: "Skipped — container not reachable, so the zone's real state is unknown",
                detail: base)
        }

        if flag && !zoneExistedBefore {
            return ICloudDiagnosticProbe(
                id: "ck.zoneFlag",
                title: "Persisted zone-created flag",
                section: .container,
                outcome: .fail,
                summary: "STALE FLAG — the app believed the zone existed, but the server had none",
                detail: base + "\nINTERPRETATION: CloudKitContainer.ensureZoneExists() returns early "
                    + "whenever this flag is set, so the app would never have created the zone and "
                    + "every save would fail with .zoneNotFound indefinitely. This sweep has since "
                    + "created the zone, which masks the state — clearing the flag "
                    + "(resetZoneCreatedFlag()) is what makes the app self-heal.\nNote the key contains "
                    + "the container id but NOT the CloudKit environment, and the container id is the "
                    + "same in Development and Production.")
        }

        return ICloudDiagnosticProbe(
            id: "ck.zoneFlag",
            title: "Persisted zone-created flag",
            section: .container,
            outcome: .info,
            summary: flag
                ? "Set, and the zone really exists — consistent"
                : "Not set — the app will provision the zone on next use",
            detail: base)
    }

    /// Whether `EncameraZone` is present on the server right now.
    private func zoneExistsOnServer() async throws -> Bool {
        let zones = try await container.privateCloudDatabase.allRecordZones()
        return zones.contains { $0.zoneID.zoneName == CloudKitSchema.zoneName }
    }

    private func subscriptionProbe(prerequisitesMet: Bool) async -> ICloudDiagnosticProbe {
        guard prerequisitesMet else {
            return ICloudDiagnosticProbe(id: "ck.subscription",
                                         title: "Zone push subscription",
                                         section: .container,
                                         outcome: .skipped,
                                         summary: "Skipped — zone not ready",
                                         detail: "")
        }
        let subscriptionID = "diag-zone-subscription"
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await container.privateCloudDatabase.modifySubscriptions(saving: [subscription], deleting: [])
            // This is a diagnostic subscription, not the app's own — remove it again.
            _ = try? await container.privateCloudDatabase.modifySubscriptions(saving: [], deleting: [subscriptionID])
            return ICloudDiagnosticProbe(
                id: "ck.subscription",
                title: "Zone push subscription",
                section: .container,
                outcome: .pass,
                summary: "Server accepts zone subscriptions for this account",
                detail: "Registered and immediately removed — this only proves the server accepts "
                    + "subscriptions; it does not touch the app's own subscription.")
        } catch {
            return ICloudDiagnosticProbe(
                id: "ck.subscription",
                title: "Zone push subscription",
                section: .container,
                outcome: .warn,
                summary: "Subscription failed: \(Self.shortError(error))",
                detail: Self.describe(error) + "\nA warning, not a failure: without a subscription saves "
                    + "still work, only cross-device push freshness suffers.")
        }
    }

    /// What is already in the zone. Answers "has this account EVER saved anything"
    /// — a zone with zero records on a user who says they have been using iCloud
    /// albums for weeks is itself the finding.
    private func zoneInventoryProbe(prerequisitesMet: Bool) async -> ICloudDiagnosticProbe {
        guard prerequisitesMet else {
            return ICloudDiagnosticProbe(id: "ck.inventory",
                                         title: "Records already in the zone",
                                         section: .container,
                                         outcome: .skipped,
                                         summary: "Skipped — zone not ready",
                                         detail: "")
        }
        do {
            let records = try await fetchAllZoneRecordTypes()
            var counts: [String: Int] = [:]
            for type in records { counts[type, default: 0] += 1 }
            let breakdown = counts.isEmpty
                ? "empty"
                : counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            return ICloudDiagnosticProbe(
                id: "ck.inventory",
                title: "Records already in the zone",
                section: .container,
                outcome: .info,
                summary: "\(records.count) record(s) — \(breakdown)",
                detail: "Enumerated with CKFetchRecordZoneChangesOperation from a nil token (the same "
                    + "mechanism the app's delta sync uses), so it needs no queryable index. Metadata "
                    + "only — no assets are downloaded.")
        } catch {
            return ICloudDiagnosticProbe(id: "ck.inventory",
                                         title: "Records already in the zone",
                                         section: .container,
                                         outcome: .warn,
                                         summary: "Could not enumerate the zone: \(Self.shortError(error))",
                                         detail: Self.describe(error))
        }
    }

    /// Enumerates the zone from a nil change token and returns each record's type.
    /// `desiredKeys = []` keeps it to metadata — no asset bytes are pulled.
    private func fetchAllZoneRecordTypes() async throws -> [String] {
        var types: [String] = []
        var token: CKServerChangeToken?
        var moreComing = true

        while moreComing {
            let (batchTypes, newToken, more) = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<([String], CKServerChangeToken?, Bool), Error>) in
                let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                config.previousServerChangeToken = token
                config.desiredKeys = []
                let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID],
                                                                  configurationsByRecordZoneID: [zoneID: config])
                operation.qualityOfService = .userInitiated

                var found: [String] = []
                var nextToken: CKServerChangeToken?
                var more = false

                operation.recordWasChangedBlock = { _, result in
                    if case .success(let record) = result { found.append(record.recordType) }
                }
                operation.recordZoneFetchResultBlock = { _, result in
                    if case .success(let success) = result {
                        nextToken = success.serverChangeToken
                        more = success.moreComing
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: (found, nextToken, more))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                container.privateCloudDatabase.add(operation)
            }
            types.append(contentsOf: batchTypes)
            token = newToken
            moreComing = more
            // A server that keeps saying moreComing without advancing the token
            // would spin forever; treat a nil token as the end of the road.
            if newToken == nil { break }
        }
        return types
    }

    // MARK: - Section: Write Path

    /// Saves a real `EncAlbum` record. This is the probe that catches an undeployed
    /// Production schema — CloudKit rejects an unknown record type with
    /// `.invalidArguments` / `.unknownItem`, which reads nothing like "your iCloud
    /// is broken" but is exactly that, for everyone on that environment.
    private func albumRecordWriteProbe(prerequisitesMet: Bool) async
        -> (probe: ICloudDiagnosticProbe, recordID: CKRecord.ID?) {
        guard prerequisitesMet else {
            return (ICloudDiagnosticProbe(id: "ck.albumWrite",
                                          title: "Write EncAlbum record (schema)",
                                          section: .writePath,
                                          outcome: .skipped,
                                          summary: "Skipped — zone not ready",
                                          detail: ""), nil)
        }
        let recordID = CKRecord.ID(recordName: "\(Self.probeRecordPrefix)Album-\(UUID().uuidString)",
                                   zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitSchema.EncAlbum.recordType, recordID: recordID)
        record[CloudKitSchema.EncAlbum.encName] = "diagnostic-probe" as CKRecordValue
        record[CloudKitSchema.EncAlbum.createdAt] = Date() as CKRecordValue
        record[CloudKitSchema.EncAlbum.isHidden] = Int64(0) as CKRecordValue
        record[CloudKitSchema.EncAlbum.schemaVersion] = CloudKitSchema.currentSchemaVersion as CKRecordValue

        do {
            _ = try await container.privateCloudDatabase.save(record)
            return (ICloudDiagnosticProbe(id: "ck.albumWrite",
                                          title: "Write EncAlbum record (schema)",
                                          section: .writePath,
                                          outcome: .pass,
                                          summary: "EncAlbum accepted — the record type is deployed here",
                                          detail: "recordID=\(recordID.recordName)"), recordID)
        } catch {
            return (ICloudDiagnosticProbe(id: "ck.albumWrite",
                                          title: "Write EncAlbum record (schema)",
                                          section: .writePath,
                                          outcome: .fail,
                                          summary: "EncAlbum save rejected: \(Self.shortError(error))",
                                          detail: Self.describe(error) + Self.writeFailureHint(error)), nil)
        }
    }

    /// Saves an `EncMedia` record carrying a real (tiny) `CKAsset`. Asset upload is
    /// a separate server path from field writes, and it is where `.quotaExceeded`
    /// actually lands.
    private func mediaAssetWriteProbe(prerequisitesMet: Bool) async
        -> (probe: ICloudDiagnosticProbe, recordID: CKRecord.ID?, payload: Data?) {
        guard prerequisitesMet else {
            return (ICloudDiagnosticProbe(id: "ck.mediaWrite",
                                          title: "Upload EncMedia record + CKAsset",
                                          section: .writePath,
                                          outcome: .skipped,
                                          summary: "Skipped — zone not ready",
                                          detail: ""), nil, nil)
        }

        let payload = Self.probePayload()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-diag-\(UUID().uuidString).bin")
        do {
            try payload.write(to: tempURL)
        } catch {
            return (ICloudDiagnosticProbe(id: "ck.mediaWrite",
                                          title: "Upload EncMedia record + CKAsset",
                                          section: .writePath,
                                          outcome: .fail,
                                          summary: "Could not stage the probe payload on disk",
                                          detail: Self.describe(error)), nil, nil)
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let recordID = CKRecord.ID(recordName: "\(Self.probeRecordPrefix)Media-\(UUID().uuidString)",
                                   zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitSchema.EncMedia.recordType, recordID: recordID)
        record[CloudKitSchema.EncMedia.albumID] = "diagnostic-probe" as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaID] = recordID.recordName as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaType] = Int64(0) as CKRecordValue
        record[CloudKitSchema.EncMedia.createdAt] = Date() as CKRecordValue
        record[CloudKitSchema.EncMedia.sizeBytes] = Int64(payload.count) as CKRecordValue
        record[CloudKitSchema.EncMedia.schemaVersion] = CloudKitSchema.currentSchemaVersion as CKRecordValue
        record[CloudKitSchema.EncMedia.encBlob] = CKAsset(fileURL: tempURL)

        do {
            _ = try await container.privateCloudDatabase.save(record)
            return (ICloudDiagnosticProbe(id: "ck.mediaWrite",
                                          title: "Upload EncMedia record + CKAsset",
                                          section: .writePath,
                                          outcome: .pass,
                                          summary: "Uploaded \(payload.count) bytes as a CKAsset — writes work",
                                          detail: "recordID=\(recordID.recordName)"), recordID, payload)
        } catch {
            return (ICloudDiagnosticProbe(id: "ck.mediaWrite",
                                          title: "Upload EncMedia record + CKAsset",
                                          section: .writePath,
                                          outcome: .fail,
                                          summary: "Asset upload rejected: \(Self.shortError(error))",
                                          detail: Self.describe(error) + Self.writeFailureHint(error)), nil, nil)
        }
    }

    private func readBackProbe(recordID: CKRecord.ID?, expectedBytes: Data?) async -> ICloudDiagnosticProbe {
        func probe(_ outcome: ICloudDiagnosticOutcome, _ summary: String, _ detail: String) -> ICloudDiagnosticProbe {
            ICloudDiagnosticProbe(id: "ck.readBack",
                                  title: "Read the uploaded asset back",
                                  section: .writePath,
                                  outcome: outcome,
                                  summary: summary,
                                  detail: detail)
        }
        guard let recordID, let expectedBytes else {
            return probe(.skipped, "Skipped — nothing was uploaded", "")
        }
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            guard let asset = record[CloudKitSchema.EncMedia.encBlob] as? CKAsset,
                  let url = asset.fileURL,
                  let data = try? Data(contentsOf: url) else {
                return probe(.fail, "The record came back without a readable asset",
                             "recordID=\(recordID.recordName)")
            }
            guard data == expectedBytes else {
                return probe(.fail,
                             "Round-tripped \(data.count) bytes, expected \(expectedBytes.count)",
                             "recordID=\(recordID.recordName)")
            }
            return probe(.pass, "Round-tripped \(data.count) bytes intact", "")
        } catch {
            return probe(.fail, "Fetch failed: \(Self.shortError(error))", Self.describe(error))
        }
    }

    private func cleanupProbe(recordIDs: [CKRecord.ID]) async -> ICloudDiagnosticProbe {
        guard !recordIDs.isEmpty else {
            return ICloudDiagnosticProbe(id: "ck.cleanup",
                                         title: "Remove probe records",
                                         section: .writePath,
                                         outcome: .skipped,
                                         summary: "Skipped — nothing was written",
                                         detail: "")
        }
        do {
            _ = try await container.privateCloudDatabase.modifyRecords(saving: [], deleting: recordIDs)
            return ICloudDiagnosticProbe(id: "ck.cleanup",
                                         title: "Remove probe records",
                                         section: .writePath,
                                         outcome: .pass,
                                         summary: "Deleted \(recordIDs.count) probe record(s)",
                                         detail: "")
        } catch {
            return ICloudDiagnosticProbe(
                id: "ck.cleanup",
                title: "Remove probe records",
                section: .writePath,
                outcome: .warn,
                summary: "Could not delete probe record(s): \(Self.shortError(error))",
                detail: Self.describe(error) + "\nHarmless to the diagnosis; the records are named "
                    + "\(Self.probeRecordPrefix)* and can be removed from the CloudKit dashboard.")
        }
    }

    // MARK: - Error interpretation

    /// Interprets a write failure. These mappings are the actionable core of the
    /// sweep — each implies a different thing to tell the user, and they are the
    /// intended basis for the follow-up preflight UX.
    public static func writeFailureHint(_ error: Error) -> String {
        guard let ckError = error as? CKError else { return "" }
        switch ckError.code {
        case .quotaExceeded:
            return "\nINTERPRETATION: the user's iCloud storage is FULL. Nothing about the app or the "
                + "account is misconfigured — they need to free space or upgrade iCloud+."
        case .notAuthenticated:
            return "\nINTERPRETATION: no usable iCloud credential. Either signed out, or the account "
                + "needs re-authentication in Settings."
        case .permissionFailure:
            return "\nINTERPRETATION: signed in but not permitted to write to this container — "
                + "typically this app's switch is off under Settings › Apple ID › iCloud › Apps Using "
                + "iCloud, or iCloud Drive itself is off."
        case .managedAccountRestricted:
            return "\nINTERPRETATION: a managed (MDM/education) Apple ID barred from CloudKit."
        case .invalidArguments, .unknownItem:
            return "\nINTERPRETATION: the server does not recognise this record type or field — the "
                + "CloudKit SCHEMA is not deployed in this environment. An app/deploy problem, not a "
                + "user problem. Check the CloudKit dashboard for the environment named in "
                + "build.environment."
        case .networkUnavailable, .networkFailure:
            return "\nINTERPRETATION: transient connectivity. Retry."
        case .requestRateLimited, .zoneBusy, .serviceUnavailable:
            return "\nINTERPRETATION: server-side throttling; retry after "
                + "\(ckError.retryAfterSeconds.map { "\($0)s" } ?? "the suggested interval")."
        case .serverRejectedRequest:
            return "\nINTERPRETATION: the server rejected the request outright — usually a container "
                + "or schema configuration problem."
        default:
            return ""
        }
    }

    public static func shortError(_ error: Error) -> String {
        if let ckError = error as? CKError {
            return ".\(ckError.code) (\(ckError.code.rawValue))"
        }
        return error.localizedDescription
    }

    public static func describe(_ error: Error) -> String {
        guard let ckError = error as? CKError else {
            return String(reflecting: error)
        }
        var lines = ["CKError .\(ckError.code) (code \(ckError.code.rawValue))"]
        if let retry = ckError.retryAfterSeconds {
            lines.append("retryAfterSeconds=\(retry)")
        }
        if let serverMessage = ckError.errorUserInfo["ServerErrorDescription"] as? String {
            lines.append("serverErrorDescription=\(serverMessage)")
        }
        if let partial = ckError.partialErrorsByItemID, !partial.isEmpty {
            for (item, itemError) in partial {
                lines.append("partial[\(item)] = \(shortError(itemError))")
            }
        }
        lines.append("localizedDescription=\(ckError.localizedDescription)")
        return lines.joined(separator: "\n")
    }

    /// A small deterministic payload — a real asset upload, but small enough that a
    /// quota-exceeded account still fails for the right reason rather than because
    /// the probe itself was large.
    static func probePayload() -> Data {
        Data(repeating: 0x7E, count: 4096)
    }
}
