# PostScript Printer Description (PPD) Transformation

This document details the transformation of the HP LaserJet Pro P1102 PPD (PostScript Printer Description) file from the upstream foomatic template to our customized, sandbox-compliant native version.

It explains **what** changed between [original.ppd](original.ppd) (upstream) and [HP_LaserJet_Professional_P1102.ppd](HP_LaserJet_Professional_P1102.ppd) (our version), and **why** these changes were necessary for native printing on Apple Silicon (macOS ARM64).

---

## 1. Upstream PPD Architecture (The "Foomatic" Way)

The [original.ppd](original.ppd) comes from the OpenPrinting `foo2zjs` driver database. 

> [!NOTE]
> For detailed instructions on obtaining the original PPD template from the upstream repository, see **[REPRODUCTION_GUIDE.md](REPRODUCTION_GUIDE.md)**.

It is designed for legacy Linux/UNIX printing systems using the **Foomatic** print wrapper stack:

```
[Mac Application] ➔ [CUPS Spooler]
                          │
                          ▼
            [foomatic-rip] (Perl Filter Script)
                          │ (Parses Foomatic comments in PPD)
                          ▼
             [Ghostscript] (gs) (Renders PS/PDF to PBM)
                          │
                          ▼
             [foo2zjs] (Compresses PBM to ZjStream)
                          │
                          ▼
                  [usb] (CUPS Backend)
```

In this architecture, options like Resolution, Paper Size, and Media Tray are defined using Foomatic-specific XML/PPD comment markers (e.g., `*FoomaticRIPOption`, `*FoomaticRIPOptionSetting`). When a print job runs, the `foomatic-rip` filter parses the PPD comments, dynamically constructs a command-line string (like `foo2zjs-wrapper -z2 -P -L0 ...`), launches Ghostscript as a subprocess to rasterize the file, and then pipes the result through `foo2zjs` to produce the final printer protocol stream.

---

## 2. Why the Legacy PPD Fails on macOS

On modern macOS (especially on Apple Silicon), this legacy architecture breaks for three primary reasons:

1. **CUPS Sandbox Restrictions:** macOS enforces a very strict sandbox for CUPS filters. Subprocesses launched by filters are heavily restricted. Running a Perl interpreter (`foomatic-rip`), launching Homebrew-compiled Ghostscript (`gs`), and executing separate shell scripts is strictly blocked, resulting in permission errors (`Sandbox Violation: deny process-fork`).
2. **Missing Dependencies:** Default macOS installations do not bundle Perl wrappers or Ghostscript. Forcing users to install heavy developer dependencies via Homebrew makes the driver fragile and hard to deploy.
3. **100 DPI Fallback Bug:** Because macOS CUPS does not run the `foomatic-rip` parser, it cannot read the legacy resolution comments (`*FoomaticRIPOption Resolution`). Lacking a standard resolution definition, macOS falls back to an unconfigured `100x100 DPI` state. This causes the custom filters to suffer division-by-zero crashes when translating sizes.

---

## 3. Our Native PPD Architecture (The Modern Way)

To solve these sandbox and dependency issues, we transitioned to a **100% native, zero-dependency, direct filter** architecture:

```
[Mac Application] ➔ [CUPS Spooler]
                          │ (Natively renders PDF to Raster)
                          ▼
             [rastertozjs] (Native C Filter)
                          │ (Reads CUPS Raster, compresses to ZJS)
                          ▼
                  [usb] (CUPS Backend)
```

By switching the print queue's input stream format to standard **CUPS Raster** (`application/vnd.cups-raster`), we leverage macOS's own internal PDF rendering system (`cgpdftoraster`). This completely bypasses the need for Ghostscript! 

Our single 20KB compiled C binary, [rastertozjs](rastertozjs), receives the raw raster scanlines directly inside the sandbox, translates them into the ZjStream wire format, and writes them to stdout for the CUPS USB backend to pick up.

---

## 4. Detailed Diff Analysis and Rationale

Below are the exact manual modifications applied to the PPD to enable this native pipeline.

### Modification A: Redirecting the Filter Pipeline

#### The Diff:
```diff
-*cupsFilter:	"application/vnd.cups-postscript 100 foomatic-rip"
-*cupsFilter:	"application/vnd.cups-pdf 0 foomatic-rip"
-*%pprRIP:        foomatic-rip other
+*cupsFilter:	"application/vnd.cups-raster 0 /Library/Printers/foo2zjs-str4ngemd/filter/rastertozjs"
```

#### Why:
* **Upstream:** Tells CUPS to pass PostScript or PDF files to the Foomatic wrapper script.
* **Ours:** Tells CUPS that this printer consumes **CUPS Raster format**, and designates our native binary [rastertozjs](rastertozjs) as the sole filter. macOS automatically loads its own high-quality PDF rasterizer (`cgpdftoraster`) to feed our filter.

---

### Modification B: Standardizing the Resolution Options

#### The Diff:
```diff
-*FoomaticRIPOption Resolution: enum CmdLine A 130
-*FoomaticRIPOptionSetting Resolution=1200x600dpi: "-r1200x600 "
+*OpenUI *Resolution/Resolution: PickOne
+*OrderDependency: 100 AnySetup *Resolution
+*DefaultResolution: 600x600dpi
+*Resolution 600x600dpi/600x600 DPI: "<</HWResolution[600 600]>>setpagedevice"
+*Resolution 1200x600dpi/1200x600 DPI: "<</HWResolution[1200 600]>>setpagedevice"
+*CloseUI: *Resolution
```

#### Why:
* **Upstream:** Used non-standard foomatic comments to construct command-line parameters for `foo2zjs`. Because macOS does not parse foomatic comments, the resolution mapping failed, falling back to 100 DPI.
* **Ours:** Defines a standard PostScript `Resolution` UI group. When you select a resolution in the macOS print panel, CUPS executes the standard PostScript `setpagedevice` command:
  * For 600 DPI: `<</HWResolution[600 600]>>setpagedevice`
  * For 1200 DPI: `<</HWResolution[1200 600]>>setpagedevice`
* **C Filter Integration:** This ensures that the raster stream generated by macOS contains the chosen dimensions in its page header. The native filter [rastertozjs](rastertozjs) parses `header.HWResolution[0]` and `header.HWResolution[1]` to dynamically configure the print resolution and bits-per-pixel (Bpp) value.
  > [!TIP]
  > For a detailed explanation of how 1200x600 DPI uses 2-bit pulse-width modulation to generate rich grays and smooth edges, see [DPI_AND_HALFTONING.md](DPI_AND_HALFTONING.md).

---

### Modification C: Simplifying Driver Branding

#### The Diff:
```diff
-*ShortNickName: "HP Las.Jet Pro P1102 foo2zjs-z2"
-*NickName:      "HP LaserJet Pro P1102 Foomatic/foo2zjs-z2 (recommended)"
+*ShortNickName: "HP LaserJet Pro P1102 Native"
+*NickName:      "HP LaserJet Pro P1102 Native"
```

#### Why:
* Simplifies the branding so that the printer displays cleanly as `HP LaserJet Pro P1102 Native` inside macOS System Settings and print sheets, avoiding confusing "Foomatic" developer branding.

---

## 5. What About the Remaining Foomatic Comments?

If you inspect [HP_LaserJet_Professional_P1102.ppd](HP_LaserJet_Professional_P1102.ppd), you will see that other option blocks (like Paper Source `*InputSlot`, Media Type `*MediaType`, and Print Density `*Density`) still contain legacy Foomatic comment lines, such as:
```text
*FoomaticRIPOption InputSlot: enum CmdLine A
*FoomaticRIPOptionSetting InputSlot=Upper: "-s1 "
```

### Why we kept them:
1. **Harmlessness:** These comment tags are ignored completely by the native CUPS workflow. Removing them is not required since CUPS skips any unrecognized line starting with `*%` or custom non-standard attributes.
2. **UI Mapping:** The parent groups (e.g. `*OpenUI *InputSlot`) and option values (e.g. `*InputSlot Upper/Upper or Only One InputSlot`) are standard Adobe PPD parameters. macOS parses these to construct the dropdown options in the native print dialog.
3. **C Filter Options Parsing:** When a user prints, CUPS bundles these UI choices into the 5th argument (`argv[4]`) of the filter execution command (e.g., `media=Letter InputSlot=Upper MediaType=Standard Density=Density3`). Our patched [rastertozjs](rastertozjs) C filter parses `argv[4]` directly, extracting the values and mapping them to their corresponding ZJS codes.

---

## Further Reading
* **[REPRODUCTION_GUIDE.md](REPRODUCTION_GUIDE.md)** - Learn how to build the filter binary and get original files.
* **[ARCHITECTURE.md](ARCHITECTURE.md)** - Details on components layout and problem-solving history.
* **[COMPARISON.md](COMPARISON.md)** - Summary of dynamic vs. hardcoded driver features.
* **[DPI_AND_HALFTONING.md](DPI_AND_HALFTONING.md)** - Technical details of 1-bit and 2-bit laser halftone rendering.
* **[RESEARCH_HISTORY.md](RESEARCH_HISTORY.md)** - Context on protocol reverse engineering.
* **[README.md](README.md)** - Step-by-step installation instructions.
