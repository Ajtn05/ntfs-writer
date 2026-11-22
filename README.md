# NTFS Writer

NTFS Writer is a small Finder companion for Apple silicon Macs running macOS 27 or later. It uses the notarized TT NTFS Native 0.4.2 driver through Apple’s FSKit. The app uses Disk Arbitration for mounting and ejecting, while Finder handles your file transfers.

## Use

1. Download and unzip the app from [GitHub Releases](https://github.com/Ajtn05/ntfs-writer/releases/latest), or build it locally using the instructions below. Open **NTFS Writer** and click **Install Driver** if prompted.
2. In System Settings, go to **General → Login Items & Extensions → By Category → File System Extensions** and enable **TT NTFS Native**.
3. Connect the NTFS drive. If the app shows **Read only**, click **Enable Writing**. For a mounted volume, **Check Writing** verifies access using a temporary one-byte file that the app removes.
4. Open the volume in Finder. Use the eject button when you finish. The button ejects the whole disk, including any other volumes on it.

If a drive stays read-only after the extension is enabled, eject it from Windows before disconnecting it, or fully shut down Windows before unplugging it. Use Windows to check a drive marked dirty.

The release app uses an ad hoc signature and has no Apple notarization. For a local build, follow the instructions below. The bundled driver retains its original Developer ID signature and notarization. [Apple’s guide to opening downloaded Mac apps](https://support.apple.com/en-us/102445)

## Build

Run `./build.sh` on an Apple silicon Mac with Xcode and the macOS 27 SDK. The script verifies the pinned upstream driver disk image, builds the native Swift app, and signs `Build/NTFS Writer.app` locally. Setup verifies the driver's Developer ID signature before copying it to `~/Applications`.

The bundled driver is an unmodified GPL-2.0 release. Its source archive, license, and upstream build instructions are available alongside the app download. [TT NTFS Native 0.4.2](https://github.com/dr-kbadawi/ttntfs/releases/tag/v0.4.2) · [Source tree](https://github.com/dr-kbadawi/ttntfs/tree/f61228f9c2f41c4d6d3d4b4cb1a6b517eaf6476a)
