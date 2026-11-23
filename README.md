# MacZipper

A minimal, pure-black native macOS archive extractor for `.zip`, `.rar`, `.7z`, and `.tar` archives.

**Version:** `0.1.0` · **Author:** Aaron Lacap (2026)

---

## Features

- **Minimal Black UI**: Native SwiftUI & AppKit dark interface with hairline borders and zero clutter.
- **Fast Native Engines**: Uses macOS `ditto`/`unzip` for ZIPs, `unar`/`unrar`/`7zz`/`bsdtar` for RAR & 7Z, and `bsdtar` for TAR archives.
- **Accurate Progress Bars**: Real-time, byte-weighted progress tracking with percentage readout and item counts.
- **Output Folder Picker**: Choose a persistent output folder or extract alongside the source archive.
- **Smart Extraction**: Prevents double-nested folders, skips secondary multi-part RAR volumes (`.part2.rar`), handles encrypted archives, and lets you choose between renaming (`Folder 2`) or replacing existing folders.
- **Instant Utility Options**: Auto-extract on drop, reveal in Finder, move archive to Trash, or auto-quit after extraction.

---

## Quick Tutorial

### 1. Extract an Archive
1. Open **MacZipper** from `/Applications/MacZipper.app` (or press `Cmd + O` after launching).
2. *(Optional)* Click **Choose…** in the bottom **Output** bar to set a custom destination folder, or leave it on **Same as archive**.
3. Drag and drop any `.zip`, `.rar`, `.7z`, or `.tar` (`.tar.gz`, `.tgz`, `.tar.bz2`, `.tar.xz`) file onto the window—or click **Choose File**.
4. If the archive is password-protected, enter the password when prompted and press **Unlock**.
5. Once complete, click **Reveal in Finder** or **Open**.

### 2. Preferences
Click the sliders icon in the top-right corner to toggle:
- **Auto-extract on drop**
- **Reveal in Finder when done**
- **Move archive to Trash after**
- **Quit app after extraction**
- **If exists**: `Rename` (keeps both) or `Replace`

### 3. Full RAR5 & Encrypted RAR Support (Optional)
macOS includes `bsdtar` out of the box for standard `.rar` files. For full RAR5 and password-protected `.rar` support, install `unar` via Homebrew:

```bash
brew install unar
```

MacZipper detects `unar` automatically (and bundles it when present at build time).

---

## Build & Install from Source

Requires **macOS 14+** and **Swift 6+**.

```bash
# Run unit tests
swift test

# Build MacZipper.app
./scripts/build_app.sh

# Install to /Applications
rm -rf /Applications/MacZipper.app
cp -R build/MacZipper.app /Applications/MacZipper.app
```
