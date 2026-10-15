import Foundation
import XperiaRescueCore

enum PlatformToolsInstallerError: LocalizedError {
    case badResponse(Int)
    case unzipFailed(Int32)
    case missingTools

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "Google's server answered with HTTP \(code)."
        case .unzipFailed(let status): return "Unzipping platform-tools failed (ditto exit code \(status))."
        case .missingTools: return "The download did not contain adb and fastboot."
        }
    }
}

/// Downloads Google's official platform-tools (adb + fastboot) into the app's
/// support folder. They are fetched at runtime rather than shipped in the app
/// because Google's SDK licence does not allow redistributing them.
enum PlatformToolsInstaller {
    static func install(into supportDirectory: URL) async throws {
        let (downloaded, response) = try await URLSession.shared.download(from: PlatformTools.downloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: downloaded)
            throw PlatformToolsInstallerError.badResponse(http.statusCode)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let staging = supportDirectory.appendingPathComponent("platform-tools-staging", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let zip = staging.appendingPathComponent("platform-tools.zip")
        try fileManager.moveItem(at: downloaded, to: zip)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        try ditto.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                ditto.waitUntilExit()
                continuation.resume()
            }
        }
        guard ditto.terminationStatus == 0 else { throw PlatformToolsInstallerError.unzipFailed(ditto.terminationStatus) }

        let extracted = staging.appendingPathComponent("platform-tools", isDirectory: true)
        guard fileManager.isExecutableFile(atPath: extracted.appendingPathComponent("adb").path),
              fileManager.isExecutableFile(atPath: extracted.appendingPathComponent("fastboot").path) else {
            throw PlatformToolsInstallerError.missingTools
        }
        let destination = supportDirectory.appendingPathComponent("platform-tools", isDirectory: true)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: extracted, to: destination)
    }
}
