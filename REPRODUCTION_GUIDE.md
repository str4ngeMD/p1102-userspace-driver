# Reproduction Guide: Building from Upstream Sources

This guide documents the origin of the upstream files used in this project and explains how to compile the native filter binary (`rastertozjs`) and configure the driver from scratch.

---

## 1. Upstream Sources & Reference Files

To rebuild or understand the foundation of this driver, you need files from three upstream sources: the `foo2zjs` driver database/source code, the PostScript Printer Description (PPD) templates, and the HP LaserJet firmware.

### A. The C Source Code (`foo2zjs`)
* **Source:** OpenPrinting Upstream Repository
* **URL:** [github.com/OpenPrinting/foo2zjs](https://github.com/OpenPrinting/foo2zjs)
* **Description:** The open-source `foo2zjs` driver suite compiles raster bitmaps into the ZjStream protocol used by Zenographics-based printers (like the HP LaserJet Pro P1102).

### B. The Original PPD (`original.ppd`)
* **Source:** OpenPrinting Upstream Repository
* **URL:** [github.com/OpenPrinting/foo2zjs/blob/main-fixes/PPD/HP-LaserJet_Pro_P1102.ppd](https://github.com/OpenPrinting/foo2zjs/blob/main-fixes/PPD/HP-LaserJet_Pro_P1102.ppd)
* **Description:** Unlike legacy setups where a PPD must be dynamically compiled from templates using `foomatic-db-engine` at build time, this PPD was already fully compiled and available as part of the upstream `foo2zjs` repository under the file path `PPD/HP-LaserJet_Pro_P1102.ppd`. The [original.ppd](original.ppd) file in this repository is a copy of that upstream file. It is designed for legacy Linux stacks and relies on a Perl script wrapper (`foomatic-rip`) to render files using Ghostscript.

### C. The HP Firmware (`sihpP1102.dl`)
* **Source:** HP Proprietary Driver Package (via Linux HPLIP)
* **How to acquire:** 
  1. On a Linux system (or Linux VM, e.g., Ubuntu), install HPLIP and run the plugin helper to download the proprietary files:
     ```bash
     sudo apt install hplip
     hp-plugin -i
     ```
  2. Locate the compressed firmware file:
     `/usr/share/hplip/data/firmware/hp_laserjet_professional_p1102.fw.gz`
  3. Decompress the file without deleting the original:
     ```bash
     gunzip -k hp_laserjet_professional_p1102.fw.gz
     ```
     This produces `hp_laserjet_professional_p1102.fw`.
  4. Compare the files: By comparing file size (`ls -l`) and content checksums, we verified that the extracted `.fw` file is identical to the `.dl` firmware file.
* **Convenience:** A copy of this extracted firmware is stored in this repository as [firmware/sihpP1102.dl](firmware/sihpP1102.dl).

---

## 2. Compilation and Patching

Since the original upstream `foo2zjs` relies on Ghostscript to convert PDF to PBM scanlines, it fails under the macOS CUPS sandbox. We patched `foo2zjs.c` to accept native CUPS Raster format (`application/vnd.cups-raster`) directly.

### Prerequisites
Install the macOS command-line compiler tools. The macOS SDK natively bundles all necessary CUPS headers (`<cups/cups.h>`, `<cups/raster.h>`), so no third-party libraries are needed.
```bash
xcode-select --install
```

### Steps to Compile
1. **Clone the Upstream Repository:**
   ```bash
   git clone https://github.com/OpenPrinting/foo2zjs.git foo2zjs-src
   ```
2. **Apply our C Raster Patch:**
   Apply [foo2zjs_cups.patch](foo2zjs_cups.patch) to the source tree to insert our custom `do_cups_raster` filter driver:
   ```bash
   cd foo2zjs-src
   patch -p1 < ../foo2zjs_cups.patch
   ```
3. **Compile Natively:**
   Compile the binary natively for Apple Silicon ARM64, linking to the system CUPS library (`-lcups`):
   ```bash
   clang -O2 -Wall -DcupsFilter -I. -lcups \
     foo2zjs.c jbig.c jbig_ar.c \
     -o rastertozjs
   ```
4. **Deploy and Clean Up:**
   Copy the newly compiled binary into the root of this project and clean up the temporary directory:
   ```bash
   cp rastertozjs ../rastertozjs
   cd ..
   rm -rf foo2zjs-src
   ```

---

## 3. PPD Transformations

To pair macOS's native rendering pipeline with our newly compiled binary, we manually modified [HP_LaserJet_Professional_P1102.ppd](HP_LaserJet_Professional_P1102.ppd) from its upstream `original.ppd` state.

* **Redirected the filter pipeline:** We changed the cupsFilter target from `foomatic-rip` to our native `rastertozjs` binary, instructing macOS to render PDF documents to standard CUPS Raster format first:
  ```text
  *cupsFilter: "application/vnd.cups-raster 0 /Library/Printers/foo2zjs-str4ngemd/filter/rastertozjs"
  ```
* **Bypassed Foomatic wrappers:** We replaced legacy comment tags (which were ignored by macOS and caused the driver to fall back to 100 DPI) with standard PostScript dictionary entries.
* **Details:** For a full line-by-line diff of our modifications and the rationale behind each one, see [PPD_TRANSFORMATION.md](PPD_TRANSFORMATION.md).
