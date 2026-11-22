import AppKit
import DiskArbitration
import IOKit

struct Volume: Identifiable {
    let disk: DADisk
    let id: UInt64
    let bsdName: String
    let name: String
    let size: Int64
    let deviceWritable: Bool
    let mount: Mount?

    init?(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              let bsd = DADiskGetBSDName(disk),
              let identity = Self.identity(disk) else { return nil }

        let internalDevice = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
        let model = description[kDADiskDescriptionDeviceModelKey as String] as? String
        guard internalDevice == false || (internalDevice == nil && model == "Disk Image") else { return nil }

        let kind = description[kDADiskDescriptionVolumeKindKey as String] as? String
        let content = description[kDADiskDescriptionMediaContentKey as String] as? String
        let path = description[kDADiskDescriptionVolumePathKey as String] as? URL
        let bsdName = String(cString: bsd)
        let mount = path.flatMap { Mount($0, device: bsdName) }
        let ntfsNames: Set<String> = ["ntfs", "ttntfs"]
        guard [kind, mount?.type].compactMap({ $0 }).contains(where: ntfsNames.contains)
            || (kind == nil && path == nil && content?.caseInsensitiveCompare("Windows_NTFS") == .orderedSame)
        else { return nil }

        self.disk = disk
        self.id = identity
        self.bsdName = bsdName
        self.name = description[kDADiskDescriptionVolumeNameKey as String] as? String ?? bsdName
        self.size = description[kDADiskDescriptionMediaSizeKey as String] as? Int64 ?? 0
        self.deviceWritable = description[kDADiskDescriptionMediaWritableKey as String] as? Bool == true
        self.mount = mount
    }

    static func identity(_ disk: DADisk) -> UInt64? {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS ? id : nil
    }
}

struct Mount: Equatable, Sendable {
    let url: URL
    let type: String
    let readOnly: Bool
    private let device: String
    private let fsID: [Int32]

    init?(_ url: URL, device: String) {
        var info = statfs()
        guard statfs(url.path, &info) == 0,
              Self.string(info.f_mntfromname) == "/dev/\(device)" else { return nil }
        self.url = url
        self.device = device
        fsID = Self.identifier(info)
        type = Self.string(info.f_fstypename)
        readOnly = info.f_flags & UInt32(MNT_RDONLY) != 0
    }

    func checkWriting() throws {
        let directory = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Self.posixError() }
        defer { close(directory) }

        var info = statfs()
        guard fstatfs(directory, &info) == 0,
              Self.identifier(info) == fsID,
              Self.string(info.f_mntfromname) == "/dev/\(device)" else {
            throw DriverError(message: "The volume changed before its write access could be checked.")
        }

        let name = ".ntfs-writer-check-\(UUID().uuidString)"
        let file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Self.posixError() }
        var byte: UInt8 = 0x4E
        let written = write(file, &byte, 1)
        let writeError = written == 1 ? nil : Self.posixError()
        let closeError = close(file) == 0 ? nil : Self.posixError()
        if unlinkat(directory, name, 0) != 0 {
            throw DriverError(message: "Could not remove the write-check file \(name). \(Self.posixError().localizedDescription)")
        }
        if let error = writeError ?? closeError { throw error }
    }

    private static func identifier(_ info: statfs) -> [Int32] {
        [info.f_fsid.val.0, info.f_fsid.val.1]
    }

    private static func string<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

@MainActor
final class Disks: ObservableObject {
    @Published private(set) var volumes: [Volume] = []
    @Published private(set) var busyID: UInt64?
    @Published private(set) var verified: [UInt64: Mount] = [:]
    @Published private(set) var readOnly: [UInt64: Mount] = [:]
    @Published var message: String?
    let session = DASessionCreate(kCFAllocatorDefault)
    private var known: [UInt64: DADisk] = [:]

    init() {
        guard let session else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            MainActor.assumeIsolated { Disks.owner(context).update(disk) }
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            MainActor.assumeIsolated { Disks.owner(context).update(disk) }
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            MainActor.assumeIsolated { Disks.owner(context).remove(disk) }
        }, context)
        DASessionSetDispatchQueue(session, .main)
    }

    deinit {
        if let session { DASessionSetDispatchQueue(session, nil) }
    }

    private static func owner(_ context: UnsafeMutableRawPointer?) -> Disks {
        Unmanaged<Disks>.fromOpaque(context!).takeUnretainedValue()
    }

    private func update(_ disk: DADisk) {
        if let id = Volume.identity(disk) { known[id] = disk }
        refresh()
    }

    private func remove(_ disk: DADisk) {
        known = known.filter { !($0.value == disk) }
        refresh()
    }

    private func refresh() {
        volumes = known.values.compactMap(Volume.init).sorted {
            ($0.name, $0.bsdName) < ($1.name, $1.bsdName)
        }
        verified = verified.filter { id, mount in volumes.contains { $0.id == id && $0.mount == mount } }
        readOnly = readOnly.filter { id, mount in volumes.contains { $0.id == id && $0.mount == mount } }
    }

    // Resolve the live device again before each operation. macOS reuses BSD names.
    private func liveDisk(_ original: Volume) throws -> DADisk {
        guard let session,
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, original.bsdName),
              Volume.identity(disk) == original.id else {
            throw DriverError(message: "The NTFS drive was disconnected.")
        }
        return disk
    }

    private func current(_ original: Volume) throws -> Volume {
        guard let volume = Volume(try liveDisk(original)) else {
            throw DriverError(message: "macOS could not identify the NTFS volume.")
        }
        return volume
    }

    func openInFinder(_ volume: Volume) {
        guard let fresh = try? current(volume), let mount = fresh.mount else {
            message = "The volume is no longer mounted."
            return
        }
        NSWorkspace.shared.open(mount.url)
    }

    func enableWriting(_ volume: Volume) async {
        guard busyID == nil else { return }
        busyID = volume.id
        message = nil
        defer {
            busyID = nil
            refresh()
        }

        do {
            var fresh = try current(volume)
            if fresh.mount?.readOnly == true {
                try await perform(.unmount, on: fresh.disk)
                let safeDisk = try liveDisk(volume)
                do {
                    try await perform(.mount, on: safeDisk)
                } catch {
                    // An ordinary read-only mount keeps the files accessible if the driver failed.
                    if let same = try? liveDisk(volume), Volume(same)?.mount == nil {
                        try? await perform(.mount, on: same)
                    }
                    throw error
                }
                fresh = try current(volume)
            } else if fresh.mount == nil {
                try await perform(.mount, on: fresh.disk)
                fresh = try current(volume)
            }

            guard let mount = fresh.mount else {
                throw DriverError(message: "macOS did not mount \(fresh.name).")
            }
            guard !mount.readOnly else { throw POSIXError(.EROFS) }
            try await Task.detached(priority: .userInitiated) { try mount.checkWriting() }.value
            if try current(volume).mount == mount {
                verified[volume.id] = mount
                readOnly[volume.id] = nil
            }
        } catch {
            verified[volume.id] = nil
            if (error as? POSIXError)?.code == .EROFS {
                readOnly[volume.id] = (try? current(volume))?.mount
                message = "\(volume.name) is read-only. Check Extension Settings. If Windows left the drive open, shut down Windows fully and reconnect it."
            } else {
                message = "Write access could not be verified. \(error.localizedDescription)"
            }
        }
    }

    func eject(_ volume: Volume) async {
        guard busyID == nil else { return }
        busyID = volume.id
        message = nil
        defer {
            busyID = nil
            refresh()
        }

        do {
            let fresh = try current(volume)
            guard let whole = DADiskCopyWholeDisk(fresh.disk), let identity = Volume.identity(whole) else {
                throw DriverError(message: "The physical disk is unavailable.")
            }
            try await perform(.unmountDisk, on: whole)
            guard Volume.identity(whole) == identity else { return }
            try await perform(.eject, on: whole)
        } catch {
            message = "The disk could not be ejected. \(error.localizedDescription)"
        }
    }

    private enum Action { case mount, unmount, unmountDisk, eject }

    private func perform(_ action: Action, on disk: DADisk) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = Unmanaged.passRetained(Operation(continuation)).toOpaque()
            let callback: DADiskMountCallback = { _, dissenter, context in
                let operation = Unmanaged<Operation>.fromOpaque(context!).takeRetainedValue()
                guard let dissenter else { operation.continuation.resume(); return }
                let status = DADissenterGetStatus(dissenter)
                let detail = DADissenterGetStatusString(dissenter) as String?
                operation.continuation.resume(throwing: DriverError(
                    message: detail ?? "Disk Arbitration returned error \(String(format: "0x%08X", status))."
                ))
            }
            switch action {
            case .mount: DADiskMount(disk, nil, 0, callback, context)
            case .unmount: DADiskUnmount(disk, 0, callback, context)
            case .unmountDisk: DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), callback, context)
            case .eject: DADiskEject(disk, 0, callback, context)
            }
        }
    }

    private final class Operation {
        let continuation: CheckedContinuation<Void, Error>

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }
    }
}
