import CoreServices
import Foundation

enum DriverSetup {
    static let bundleID = "ch.techtag.ntfs"
    static let name = "TT NTFS Native"
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems"
    )!

    static var installURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/\(name).app", isDirectory: true)
    }

    static func install(from image: URL) throws -> URL {
        let files = FileManager.default
        let target = installURL
        if files.fileExists(atPath: target.path) {
            try verify(target)
            return target
        }

        let mount = files.temporaryDirectory.appendingPathComponent("NTFS Driver \(UUID())")
        try files.createDirectory(at: mount, withIntermediateDirectories: false)
        defer { _ = rmdir(mount.path) }

        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path]) }

        let source = mount.appendingPathComponent("\(name).app", isDirectory: true)
        try verify(source)

        let applications = target.deletingLastPathComponent()
        try files.createDirectory(at: applications, withIntermediateDirectories: true)
        let staging = applications.appendingPathComponent(".ntfs-writer-\(UUID())", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        let copy = staging.appendingPathComponent(target.lastPathComponent)
        try run("/usr/bin/ditto", [source.path, copy.path])
        try verify(copy)
        try files.moveItem(at: copy, to: target)
        return target
    }

    static func register(_ url: URL) throws {
        let status = LSRegisterURL(url as CFURL, true)
        guard status == noErr else {
            throw DriverError(message: "macOS could not register the driver (\(status)).")
        }
        let module = url.appendingPathComponent("Contents/Extensions/NTFSExtension.appex")
        try run("/usr/bin/pluginkit", ["-a", module.path])
    }

    private static func verify(_ app: URL) throws {
        let deviceRequirement = "anchor apple generic and identifier \"\(bundleID)\" "
            + "and certificate leaf[subject.OU] = \"HU5S996C2K\" "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(deviceRequirement)", app.path])
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: response, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DriverError(message: detail.isEmpty ? "Driver setup failed (\(process.terminationStatus))." : detail)
        }
    }
}

struct DriverError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
