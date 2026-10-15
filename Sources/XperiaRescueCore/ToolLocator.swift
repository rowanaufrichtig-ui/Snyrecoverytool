import Foundation

public enum ExternalTool: String, CaseIterable, Sendable {
    case adb
    case fastboot
    case newflasher

    public var title: String {
        switch self {
        case .adb: return "adb"
        case .fastboot: return "fastboot"
        case .newflasher: return "newflasher"
        }
    }
}

/// Finds adb, fastboot and newflasher on the Mac.
///
/// Search order:
/// - newflasher: inside the app bundle, then the app's support folder, then PATH / Homebrew.
/// - adb / fastboot: the copy of Google's platform-tools the app downloaded,
///   then Homebrew, the Android SDK and PATH.
public struct ToolLocator {
    public var homeDirectory: URL
    public var bundledToolsDirectory: URL?
    public var supportDirectory: URL
    public var pathEnvironment: String?
    public var isExecutable: (String) -> Bool

    public init(
        homeDirectory: URL,
        bundledToolsDirectory: URL?,
        supportDirectory: URL,
        pathEnvironment: String?,
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.homeDirectory = homeDirectory
        self.bundledToolsDirectory = bundledToolsDirectory
        self.supportDirectory = supportDirectory
        self.pathEnvironment = pathEnvironment
        self.isExecutable = isExecutable
    }

    /// Where the app keeps the platform-tools it downloads.
    public var managedPlatformToolsDirectory: URL {
        supportDirectory.appendingPathComponent("platform-tools", isDirectory: true)
    }

    public func candidates(for tool: ExternalTool) -> [URL] {
        let name = tool.rawValue
        var directories: [URL] = []
        switch tool {
        case .newflasher:
            if let bundledToolsDirectory { directories.append(bundledToolsDirectory) }
            directories.append(supportDirectory.appendingPathComponent("bin", isDirectory: true))
        case .adb, .fastboot:
            directories.append(managedPlatformToolsDirectory)
        }
        directories += [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            homeDirectory.appendingPathComponent("Library/Android/sdk/platform-tools"),
        ]
        for entry in (pathEnvironment ?? "").split(separator: ":") where !entry.isEmpty {
            directories.append(URL(fileURLWithPath: String(entry)))
        }

        var seen = Set<String>()
        return directories
            .map { $0.appendingPathComponent(name) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public func locate(_ tool: ExternalTool) -> URL? {
        candidates(for: tool).first { isExecutable($0.path) }
    }
}

public enum PlatformTools {
    /// Google's official download of adb + fastboot for macOS.
    public static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    /// Parses the first line of `adb version` / `fastboot --version`.
    public static func parseVersion(_ output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Version ") {
                return String(trimmed.dropFirst("Version ".count))
            }
            if trimmed.hasPrefix("fastboot version ") {
                return String(trimmed.dropFirst("fastboot version ".count))
            }
        }
        return nil
    }
}
