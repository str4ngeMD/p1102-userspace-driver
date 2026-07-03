# Feature Comparison: Native C Filter vs. Official Foomatic Driver

Here is the exact mapping of what was changed, what remains fully dynamic, and what is hardcoded in the new native pipeline.

---

## 1. What changed from the official way?

| Feature | Official Foomatic Pipeline | Our Native C Driver Pipeline |
| :--- | :--- | :--- |
| **Execution Path** | `CUPS` ➔ `foomatic-rip` ➔ `Ghostscript (gs)` ➔ `foo2zjs` (binary) | `CUPS` ➔ `cgpdftoraster` (Native macOS) ➔ `rastertozjs` (C Filter) |
| **Dependencies** | Requires heavy Ghostscript runtime and multiple Perl/bash wrapper scripts. | None. Uses macOS's built-in PDF-to-Raster rendering and our single 20KB C binary. |
| **Sandbox Compliance** | Highly vulnerable. Often blocked by macOS sandbox policies due to running external `/opt/homebrew` binaries. | 100% compliant. Runs inside the sandbox linking only to standard macOS `libcups.dylib`. |

---

## 2. Option Mapping: Dynamic vs. Hardcoded

### A. Fully Dynamic Features (No loss in capability)

*   **DPI Resolution (600x600 DPI vs. 1200x600 DPI):**
    *   **How it works:** Fully supported. When you select `1200x600 DPI` in the print dialog, `cgpdftoraster` renders a high-res image and passes `HWResolution[0]=1200` to the C filter.
    *   **The Code:** Inside the C code, `Bpp` (bits per pixel) is calculated dynamically: `Bpp = ResX / 600`. For `1200`, it sets `Bpp = 2` and downscales `ResX` to `600`, which is the exact mathematical ZjStream command sequence `foo2zjs` uses to trigger the printer's hardware-based 1200 DPI interpolation.
*   **Draft / Toner Saving (EconoMode):**
    *   **How it works:** Fully supported. Selecting `Draft` or enabling `EconoMode` in the print setup dialog passes the option to the C filter, which sets the hardware PJL envelope option `@PJL SET ECONOMODE=ON` and ZjStream parameter `ZJI_ECONOMODE = 1`.
*   **Print Density (Toner Darkness 1 to 5):**
    *   **How it works:** Fully supported. Slider adjustments in your print settings map to `@PJL SET DENSITY=[1-5]` dynamically.
*   **Paper Source (Tray Selection):**
    *   **How it works:** Supported dynamically. Selecting different input trays (Manual Feed, Upper, Middle, Lower, Auto) maps to standard ZJS tray codes dynamically.
*   **Media Type (Paper Material):**
    *   **How it works:** Supported dynamically. Selecting different media (Envelope, Labels, Recycled, Heavy, Plain) maps to the corresponding fuser/temperature control ZJS codes dynamically.

---

### B. Hardcoded / Simplified Settings

*   **Model Identification:**
    *   **Setting:** `Model = MODEL_HP_PRO` (2).
    *   **Why:** Since this driver queue and PPD are specifically built for the LaserJet Pro P1102, we hardcode the target model to prevent mismatches.
*   **Monochrome Plane Offset (`OutputStartPlane`):**
    *   **Setting:** `OutputStartPlane = 0`.
    *   **Why:** Monochrome printers expect pixel data to start at Plane 0. Color printers map black to Plane 4. Hardcoding this to `0` prevents color-plane mismatches that crash the printer controller.
*   **Duplexing:**
    *   The P1102 is physically a simplex-only printer. Any manual duplexing (printing odd pages, flipping, then printing even pages) is handled on the client-side by the macOS print spooler itself, so the lack of duplex parsing in the driver does not affect manual duplexing.
