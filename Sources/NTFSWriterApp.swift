import AppKit
import SwiftUI

@main
struct NTFSWriterApp: App {
    @StateObject private var disks = Disks()
    @StateObject private var driver = DriverState()
    @AppStorage("showsMenuBarItem") private var showsMenuBarItem = true

    var body: some Scene {
        Window("NTFS Writer", id: "volumes") {
            WriterView(disks: disks, driver: driver)
                .frame(width: 500, height: 410)
                .onAppear { driver.refresh() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    driver.refresh()
                }
                .toolbar {
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
        }
        .windowResizability(.contentSize)

        Settings {
            Form {
                Toggle("Show NTFS Writer in the menu bar", isOn: $showsMenuBarItem)
            }
            .formStyle(.grouped)
            .frame(width: 360)
            .fixedSize(horizontal: false, vertical: true)
        }

        MenuBarExtra("NTFS Writer", systemImage: "externaldrive", isInserted: $showsMenuBarItem) {
            WriterMenu()
        }
    }
}

private struct WriterMenu: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open NTFS Writer") {
            NSApp.activate()
            openWindow(id: "volumes")
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        Divider()
        Button("Quit NTFS Writer") {
            NSApp.terminate(nil)
        }
    }
}

@MainActor
final class DriverState: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var installing = false
    @Published var error: String?

    private var installedURL: URL? {
        let url = DriverSetup.installURL
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: DriverSetup.bundleID)
    }

    func refresh() {
        installed = installedURL != nil
    }

    func install() async {
        guard !installing else { return }
        guard let image = Bundle.main.url(forResource: "TT-NTFS-Native-0.4.2", withExtension: "dmg") else {
            error = "The driver disk image is missing from this copy of NTFS Writer."
            return
        }
        installing = true
        error = nil
        defer { installing = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                let app = try DriverSetup.install(from: image)
                try DriverSetup.register(app)
            }.value
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct WriterView: View {
    @ObservedObject var disks: Disks
    @ObservedObject var driver: DriverState
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("NTFS Writer").font(.title2.weight(.semibold))
                    Text("Write to Windows drives in Finder.").foregroundStyle(.secondary)
                }
            }

            setupCard

            if disks.volumes.isEmpty {
                ContentUnavailableView(
                    "No NTFS drives connected",
                    systemImage: "externaldrive",
                    description: Text("Connect a Windows-formatted NTFS drive to get started.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(disks.volumes) { volume in
                            volumeRow(volume)
                            if volume.id != disks.volumes.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }

            if let message = driver.error ?? disks.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityHidden(true)
                    ScrollView {
                        Text(message).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 50)
                    Button("Dismiss", systemImage: "xmark") {
                        if driver.error != nil { driver.error = nil } else { disks.message = nil }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                .font(.footnote)
            }
        }
        .padding(22)
    }

    private var setupCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(driver.installing ? "Installing the NTFS driver…" : driver.installed ? "TT NTFS Native" : "Install the NTFS driver")
                    .font(.subheadline.weight(.semibold))
                Text(driver.installed ? "Enable under By Category → File System Extensions." : "Uses the signed TT NTFS Native driver.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if driver.installing {
                ProgressView().controlSize(.small).accessibilityLabel("Installing the driver")
            } else if driver.installed {
                Button("Extension Settings") { openURL(DriverSetup.settingsURL) }
            } else {
                Button("Install Driver") {
                    Task {
                        await driver.install()
                        if driver.installed { openURL(DriverSetup.settingsURL) }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func volumeRow(_ volume: Volume) -> some View {
        let isVerified = disks.verified[volume.id] != nil
        let isReadOnly = volume.mount?.readOnly == true || disks.readOnly[volume.id] != nil
        let status = isVerified ? "Write enabled" : isReadOnly ? "Read only" : volume.mount == nil ? "Unmounted" : "Mounted"
        return HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.title3).foregroundStyle(.secondary)
                .frame(width: 25).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(volume.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(ByteCountFormatter.string(fromByteCount: volume.size, countStyle: .file)) · \(status)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if disks.busyID == volume.id {
                ProgressView().controlSize(.small).accessibilityLabel("Working on \(volume.name)")
            } else if !isVerified && volume.deviceWritable {
                let needsMount = volume.mount == nil || isReadOnly
                Button(needsMount ? "Enable Writing" : "Check Writing") {
                    Task { await disks.enableWriting(volume) }
                }
                .disabled(disks.busyID != nil || (needsMount && !driver.installed))
            }
            if volume.mount != nil {
                Button("Open in Finder", systemImage: "folder") { disks.openInFinder(volume) }
                    .labelStyle(.iconOnly).help("Open in Finder").disabled(disks.busyID != nil)
            }
            Button("Eject disk", systemImage: "eject") { Task { await disks.eject(volume) } }
                .labelStyle(.iconOnly).help("Eject the disk and all its volumes").disabled(disks.busyID != nil)
        }
        .controlSize(.small)
        .padding(.vertical, 10)
    }
}
