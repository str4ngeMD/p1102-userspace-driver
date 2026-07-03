# TODO / Project Roadmap

This document outlines the next engineering phases for the **HP LaserJet Pro P1102 macOS Driver** project. It is written to bring any fresh developer or AI coding assistant immediately up to speed.

---

## Current Status Summary
* **Driver Architecture:** Uses a custom C raster filter (`rastertozjs`) compiled natively for Apple Silicon (ARM64) that reads standard CUPS raster formats.
* **Firmware Uploader:** Uses a compiled, native Swift hotplug daemon (`p1102_fw_uploader`) that runs in user space via a launchd agent. It automatically monitors the USB bus via IOKit and uploads firmware if the printer is in bootloader mode (preventing loops by checking if the EWS interface is already active).
* **Installation:** Hybrid `install.sh` that deploys pre-compiled binaries (clearing quarantine attributes) or falls back to compiling from source.

---

## 📅 Roadmap Tasks

### Task 1: Decouple the C Raster Filter (`rastertozjs`)

Currently, reproducing the C filter requires cloning the upstream `foo2zjs` repository and applying a line-number-based unified patch file (`foo2zjs_cups.patch`) to `foo2zjs.c`. This is fragile if the upstream code changes.

#### Objective:
Make `rastertozjs` completely self-contained in this repository with zero external dependencies.

#### Steps:
1. **Copy JBIG Compression Files:**
   Copy the standard JBIG-kit compression files from the upstream `foo2zjs` source directly into our repository:
   * `jbig.c` / `jbig.h`
   * `jbig_ar.c` / `jbig_ar.h`
   * `zjs.h`
2. **Create Standalone `rastertozjs.c`:**
   Instead of patching `foo2zjs.c`, write a standalone `rastertozjs.c` that contains:
   * Core ZJS record-writing logic extracted from `foo2zjs.c` (e.g. `start_doc()`, `end_doc()`, `pbm_page()`, and formatting wrappers).
   * The CUPS option parsing interface (mapping tray selections, economode, and print density).
   * The `main()` entrypoint that reads `application/vnd.cups-raster` frames from stdin and feeds them to the JBIG compressor.
3. **Simplify Compilation:**
   Update `install.sh` to compile the filter directly:
   ```bash
   clang -O2 -Wall -DcupsFilter -I. -lcups rastertozjs.c jbig.c jbig_ar.c -o rastertozjs
   ```

---

### Task 2: Create a Native macOS `.pkg` Installer

Currently, installation requires checking out the repository and running `./install.sh` from the command line, which prompts for user passwords.

#### Objective:
Bundle all driver components into a standard, double-clickable macOS `.pkg` installer that handles root authorization prompts natively.

#### Steps:
1. **Prepare Install Root Directory:**
   Structure an installer payload directory:
   * `/Library/Printers/foo2zjs-str4ngemd/filter/rastertozjs`
   * `/Library/Printers/foo2zjs-str4ngemd/bin/p1102_fw_uploader`
   * `/Library/Printers/foo2zjs-str4ngemd/firmware/sihpP1102.dl`
   * `/Library/Printers/PPDs/Contents/Resources/HP_LaserJet_Professional_P1102_Native.ppd`
2. **Draft a postinstall Script:**
   Write an installer post-installation shell script to:
   * Copy the launchd plist configuration `com.str4ngemd.p1102-fw-uploader.plist` to the target user's `~/Library/LaunchAgents/` directory.
   * Dynamically replace the `/Users/REPLACE_WITH_USER_NAME` placeholder with the active GUI user's home folder path (using `/usr/bin/stat -f%Su /dev/console`).
   * Bootout any old launchd instance and load the new uploader agent into the user's bootstrap namespace.
3. **Build the Package:**
   Use the native macOS `pkgbuild` utility:
   ```bash
   pkgbuild --root ./install_root \
            --identifier "com.str4ngemd.p1102-userspace-driver" \
            --version "1.2" \
            --scripts ./scripts \
            --install-location / \
            HP_LaserJet_P1102_Native_Driver.pkg
   ```
