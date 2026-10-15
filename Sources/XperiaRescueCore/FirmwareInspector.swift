import Foundation

public enum IssueSeverity: Int, Comparable, Sendable {
    case info = 0
    case warning = 1
    case error = 2

    public static func < (lhs: IssueSeverity, rhs: IssueSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct FirmwareIssue: Hashable, Sendable {
    public let severity: IssueSeverity
    public let message: String

    public init(_ severity: IssueSeverity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

public struct FirmwareFile: Hashable, Sendable {
    public enum SkipReason: String, Sendable {
        /// newflasher never flashes persist (it holds attestation keys / calibration).
        case persist = "persist is never flashed (keeps attestation keys and sensor calibration)"
        /// newflasher never flashes partition-table sins.
        case partitionTable = "partition tables are not rewritten"
        /// Listed as NOERASE in update.xml: skipped when "keep user data" is on.
        case keptUserdata = "skipped when keeping user data"
    }

    public let name: String
    public let size: Int64
    public let partition: String
    public let alwaysSkipped: SkipReason?
    public let erasesUserData: Bool

    public init(name: String, size: Int64, partition: String, alwaysSkipped: SkipReason?, erasesUserData: Bool) {
        self.name = name
        self.size = size
        self.partition = partition
        self.alwaysSkipped = alwaysSkipped
        self.erasesUserData = erasesUserData
    }
}

/// The result of looking at a firmware folder downloaded with XperiFirm.
public struct FirmwarePackage: Sendable {
    public let folder: URL
    public let model: String?
    public let version: String?
    public let cda: String?
    public let market: String?
    public let sinFiles: [FirmwareFile]
    public let taFiles: [String]
    public let bootSinCount: Int
    /// Partition-table images in partition/ (flashed first, when the layout changes).
    public let partitionSinCount: Int
    public let bootImagesPerConfiguration: Int
    public let hasBootDelivery: Bool
    public let hasUpdateXML: Bool
    public let noEraseFiles: [String]
    public let totalBytes: Int64
    public let issues: [FirmwareIssue]

    public var hasErrors: Bool { issues.contains { $0.severity == .error } }

    public var displayName: String {
        [model, version, market].compactMap { $0 }.joined(separator: " · ")
    }

    /// Whether newflasher can preserve user data with this package.
    public var supportsKeepingUserData: Bool { hasUpdateXML && !noEraseFiles.isEmpty }

    /// Roughly how many "Processing <image>.sin" lines newflasher will print, for progress
    /// display. Files kept for user data are still announced (then skipped), persist and
    /// top-level partition images are not.
    public var estimatedFlashSteps: Int {
        sinFiles.filter { $0.alwaysSkipped == nil }.count + partitionSinCount + bootImagesPerConfiguration
    }

    public enum Compatibility: Equatable, Sendable {
        case match
        /// Both are Xperia 5 V variants but different ones (cross-flash).
        case differentVariant(firmware: String, device: String)
        /// The firmware is for a different phone altogether.
        case wrongDevice(firmware: String, device: String?)
        case unknownDevice
        case unknownFirmware
    }

    public func compatibility(withDeviceModel deviceModel: String?) -> Compatibility {
        guard let firmwareModel = model else { return .unknownFirmware }
        if !XperiaCatalog.isXperia5V(model: firmwareModel) {
            return .wrongDevice(firmware: firmwareModel, device: deviceModel)
        }
        guard let rawDevice = deviceModel, !rawDevice.isEmpty else { return .unknownDevice }
        let device = XperiaCatalog.normalizeModel(rawDevice)
        if device == firmwareModel { return .match }
        if XperiaCatalog.isXperia5V(model: device) {
            return .differentVariant(firmware: firmwareModel, device: device)
        }
        return .wrongDevice(firmware: firmwareModel, device: device)
    }
}

public enum FirmwareInspector {
    /// newflasher refuses to start with less than this much free space.
    public static let requiredFreeBytes: Int64 = 10_240 * 1024 * 1024

    public static func inspect(folder: URL, availableBytes: Int64? = nil, fileManager: FileManager = .default) -> FirmwarePackage {
        var issues: [FirmwareIssue] = []
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return emptyPackage(folder: folder, issues: [FirmwareIssue(.error, "The folder does not exist.")])
        }

        let entries = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        let updateXML = readText(folder.appendingPathComponent("update.xml"))
        let noErase = updateXML.map(parseNoEraseList) ?? []

        var sinFiles: [FirmwareFile] = []
        var taFiles: [String] = []
        var zipFiles: [String] = []
        var totalBytes: Int64 = 0

        for name in entries.sorted() {
            let url = folder.appendingPathComponent(name)
            let lower = name.lowercased()
            if lower.hasSuffix(".sin") {
                let size = fileSize(url, fileManager: fileManager)
                totalBytes += size
                sinFiles.append(makeSinFile(name: name, size: size, noErase: noErase))
            } else if lower.hasSuffix(".ta") {
                taFiles.append(name)
            } else if lower.hasSuffix(".zip") || lower.hasSuffix(".ftf") || lower.hasSuffix(".7z") || lower.hasSuffix(".rar") {
                zipFiles.append(name)
            }
        }

        let bootFolder = folder.appendingPathComponent("boot")
        let bootEntries = (try? fileManager.contentsOfDirectory(atPath: bootFolder.path)) ?? []
        let bootSinCount = bootEntries.filter { $0.lowercased().hasSuffix(".sin") }.count
        for name in bootEntries where name.lowercased().hasSuffix(".sin") {
            totalBytes += fileSize(bootFolder.appendingPathComponent(name), fileManager: fileManager)
        }
        let bootDeliveryXML = readText(bootFolder.appendingPathComponent("boot_delivery.xml"))
        let partitionEntries = (try? fileManager.contentsOfDirectory(atPath: folder.appendingPathComponent("partition").path)) ?? []
        let partitionSinCount = partitionEntries.filter { $0.lowercased().hasSuffix(".sin") }.count
        let bootImagesPerConfiguration = bootDeliveryXML.map(maxBootImagesPerConfiguration) ?? 0

        // Model / version / CDA: look at fwinfo.xml (written by XperiFirm), the
        // folder name (XperiFirm names it e.g. "XQ-DE54_Customized EU_67.2.A.3.194_R2C")
        // and update.xml.
        let metadataSources = [
            readText(folder.appendingPathComponent("fwinfo.xml")),
            folder.lastPathComponent,
            updateXML,
        ].compactMap { $0 }
        let model = metadataSources.lazy.compactMap(extractModel).first
        let version = metadataSources.lazy.compactMap(extractVersion).first
        let cda = metadataSources.lazy.compactMap(extractCDA).first
        let market = metadataSources.lazy.compactMap(extractMarket).first

        // ---- Issues -------------------------------------------------------
        if sinFiles.isEmpty && bootSinCount == 0 {
            if !zipFiles.isEmpty {
                issues.append(FirmwareIssue(.error, "No .sin files found, only archives (\(zipFiles.joined(separator: ", "))). Extract the archive first, then choose the extracted folder."))
            } else {
                issues.append(FirmwareIssue(.error, "No .sin firmware files found. Choose the folder XperiFirm created (it contains many *.sin files and a boot folder)."))
            }
        }
        if let model {
            if !XperiaCatalog.isXperia5V(model: model) {
                issues.append(FirmwareIssue(.error, "This firmware is for \(model), not an Xperia 5 V (\(XperiaCatalog.xperia5VVariants.map(\.model).joined(separator: ", ")))."))
            } else if let note = XperiaCatalog.variant(forModel: model)?.note {
                issues.append(FirmwareIssue(.info, note))
            }
        } else if !sinFiles.isEmpty {
            issues.append(FirmwareIssue(.warning, "Could not tell which model this firmware is for (no fwinfo.xml and the folder was renamed). Double-check it matches your phone's model number."))
        }
        if !sinFiles.isEmpty && bootDeliveryXML == nil {
            issues.append(FirmwareIssue(.warning, "No boot/boot_delivery.xml: the bootloader and modem firmware will not be flashed. For a full repair use a complete XperiFirm download."))
        } else if bootDeliveryXML != nil && bootImagesPerConfiguration == 0 {
            issues.append(FirmwareIssue(.warning, "boot/boot_delivery.xml lists no boot images. The download may be incomplete."))
        }
        if !sinFiles.isEmpty && (updateXML == nil || noErase.isEmpty) {
            issues.append(FirmwareIssue(.warning, "No update.xml with a NOERASE list: \"Keep user data\" is not possible with this package, flashing will erase the phone."))
        }
        if sinFiles.contains(where: { $0.alwaysSkipped == .persist }) {
            issues.append(FirmwareIssue(.info, "persist image found: it is skipped automatically to keep your attestation keys and sensor calibration."))
        }
        if let version, compareFirmwareVersions(version, XperiaCatalog.newestKnownFirmware) == .orderedAscending {
            issues.append(FirmwareIssue(.info, "This is build \(version). Build \(XperiaCatalog.newestKnownFirmware) or newer was available on \(XperiaCatalog.newestKnownFirmwareDate); check XperiFirm for your region's latest."))
        }
        if let availableBytes, availableBytes < requiredFreeBytes {
            let gb = Double(availableBytes) / 1_073_741_824
            issues.append(FirmwareIssue(.error, String(format: "Only %.1f GB free on this disk. newflasher needs at least 10 GB free next to the firmware folder.", gb)))
        }

        return FirmwarePackage(
            folder: folder,
            model: model,
            version: version,
            cda: cda,
            market: market,
            sinFiles: sinFiles,
            taFiles: taFiles,
            bootSinCount: bootSinCount,
            partitionSinCount: partitionSinCount,
            bootImagesPerConfiguration: bootImagesPerConfiguration,
            hasBootDelivery: bootDeliveryXML != nil,
            hasUpdateXML: updateXML != nil,
            noEraseFiles: noErase,
            totalBytes: totalBytes,
            issues: issues.sorted { $0.severity > $1.severity }
        )
    }

    // MARK: - Parsing helpers (public for tests)

    /// `boot_X-FLASH-ALL-B6B5.sin` → `boot`, `vendor_boot_X-FLASH-ALL-xx.sin` → `vendor_boot`.
    public static func partitionName(fromSinFile name: String) -> String {
        var base = name
        if base.lowercased().hasSuffix(".sin") { base = String(base.dropLast(4)) }
        if let range = base.range(of: "_X-FLASH", options: .caseInsensitive) {
            return String(base[..<range.lowerBound])
        }
        if let range = base.range(of: "_S1-", options: .caseInsensitive) {
            return String(base[..<range.lowerBound])
        }
        return base
    }

    /// Sony model numbers: XQ-DE54, SO-53D, SOG12, A303SO, ...
    public static func extractModel(from text: String) -> String? {
        firstMatch(#"(?<![A-Z0-9])(XQ-[A-Z]{2}[0-9]{2}|SO-[0-9]{2}[A-Z]|SOG[0-9]{2}|A[0-9]{3}SO)(?![A-Z0-9])"#, in: text.uppercased())
    }

    /// Sony software versions look like 67.2.A.3.194.
    public static func extractVersion(from text: String) -> String? {
        firstMatch(#"(?<![0-9.])([0-9]{2}\.[0-9]\.[A-Z]\.[0-9]{1,2}\.[0-9]{1,4})(?![0-9])"#, in: text)
    }

    /// Customisation (CDA) numbers look like 1325-3029.
    public static func extractCDA(from text: String) -> String? {
        firstMatch(#"(?<![0-9])(1[0-9]{3}-[0-9]{4})(?![0-9])"#, in: text)
    }

    /// "Customized EU", "Customized UK", "Commercial and Journalists"... as named by XperiFirm.
    public static func extractMarket(from text: String) -> String? {
        if let market = firstMatch(#"<(?:market|Market|MARKET)>([^<]+)</"#, in: text) { return market.trimmingCharacters(in: .whitespaces) }
        if let custom = firstMatch(#"(Customi[sz]ed [A-Za-z ]+?)(?:_|$|<)"#, in: text) { return custom.trimmingCharacters(in: .whitespaces) }
        return nil
    }

    public static func parseNoEraseList(_ updateXML: String) -> [String] {
        allMatches(#"<NOERASE>\s*([^<]+?)\s*</NOERASE>"#, in: updateXML)
    }

    /// Largest number of BOOT_IMAGES files in a single CONFIGURATION of boot_delivery.xml.
    /// newflasher flashes exactly one configuration (the one matching the phone).
    public static func maxBootImagesPerConfiguration(_ xml: String) -> Int {
        let configurations = allMatches(#"<CONFIGURATION\b[^>]*>(.*?)</CONFIGURATION>"#, in: xml, dotAll: true)
        let counts = configurations.map { configuration -> Int in
            let images = allMatches(#"<BOOT_IMAGES\b[^>]*>(.*?)</BOOT_IMAGES>"#, in: configuration, dotAll: true)
            return images.reduce(0) { $0 + allMatches(#"<FILE\b[^>]*PATH\s*=\s*"([^"]+)""#, in: $1).count }
        }
        return counts.max() ?? 0
    }

    /// Compares Sony build numbers numerically component by component (letters lexically).
    public static func compareFirmwareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".")
        let right = rhs.split(separator: ".")
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? String(left[index]) : "0"
            let r = index < right.count ? String(right[index]) : "0"
            if let li = Int(l), let ri = Int(r) {
                if li != ri { return li < ri ? .orderedAscending : .orderedDescending }
            } else if l != r {
                return l < r ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    // MARK: - Private

    private static func makeSinFile(name: String, size: Int64, noErase: [String]) -> FirmwareFile {
        let partition = partitionName(fromSinFile: name)
        let lower = name.lowercased()
        let skip: FirmwareFile.SkipReason?
        // Same substring rules newflasher uses ("ersist" and "artition").
        if lower.contains("ersist") {
            skip = .persist
        } else if lower.contains("artition") {
            skip = .partitionTable
        } else {
            skip = nil
        }
        let erases = noErase.contains(name) || partition.lowercased() == "userdata"
        return FirmwareFile(name: name, size: size, partition: partition, alwaysSkipped: skip, erasesUserData: erases)
    }

    private static func emptyPackage(folder: URL, issues: [FirmwareIssue]) -> FirmwarePackage {
        FirmwarePackage(
            folder: folder, model: nil, version: nil, cda: nil, market: nil, sinFiles: [], taFiles: [],
            bootSinCount: 0, partitionSinCount: 0, bootImagesPerConfiguration: 0, hasBootDelivery: false, hasUpdateXML: false,
            noEraseFiles: [], totalBytes: 0, issues: issues
        )
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func fileSize(_ url: URL, fileManager: FileManager) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String, dotAll: Bool = false) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: dotAll ? [.dotMatchesLineSeparators] : []) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            guard let swiftRange = Range(group, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}
