# Deep Dive: DPI, Halftoning, and Bits Per Pixel (Bpp)

This document explains the technical implementation of resolution mapping and raster encoding in the `rastertozjs` filter and the custom P1102 PPD.

---

## 1. How CUPS Handles Resolution Dynamically

In our custom PPD [HP_LaserJet_Professional_P1102.ppd](file:///Users/sorce/code/hplipmaybe/print%20lab%202/HP_LaserJet_Professional_P1102.ppd), we define the resolution options using standard CUPS keys:

```text
*OpenUI *Resolution/Resolution: PickOne
*DefaultResolution: 600x600dpi
*Resolution 600x600dpi/600x600 DPI: "<</HWResolution[600 600]>>setpagedevice"
*Resolution 1200x600dpi/1200x600 DPI: "<</HWResolution[1200 600]>>setpagedevice"
*CloseUI: *Resolution
```

1. **User Interface:** macOS reads this block and displays a **Resolution** dropdown menu in the print sheet containing two choices: `600x600 DPI` and `1200x600 DPI`.
2. **Dynamic Rendering:** When a user selects `1200x600 DPI`, the macOS PDF-to-Raster converter (`cgpdftoraster`) runs the PostScript command `<</HWResolution[1200 600]>>setpagedevice`. This renders the PDF page into a high-density bitmap of `1200` DPI horizontally by `600` DPI vertically.
3. **Stream Header:** The rasterizer writes these values into the page header of the CUPS raster stream:
   * `header.HWResolution[0] = 1200`
   * `header.HWResolution[1] = 600`
4. **C Filter Parsing:** Our C filter (`rastertozjs`) reads these header values from standard input dynamically. It maps them to the driver's internal variables:
   * `ResX = header.HWResolution[0]` (1200)
   * `ResY = header.HWResolution[1]` (600)
5. **ZjStream Translation:**
   ```c
   if (Model == MODEL_HP1020 || Model == MODEL_HP_PRO || Model == MODEL_HP_PRO_CP)
   {
       Bpp = ResX / 600;
       ResX = 600;
   }
   ```
   For `1200` DPI, it sets `Bpp = 2` and downscales the stream's logical resolution `ResX` back to `600`. This triggers the printer's hardware-based FastRes 1200 mode.

---

## 2. What is Bits Per Pixel (Bpp)?

A laser printer is a binary device at the physical engine level. It has **no gray toner** (the toner is solid black), and the laser can only turn **ON** (making a black dot) or **OFF** (leaving a white space). 

To print complex images and shades of gray, the driver uses **Halftoning** and **Laser Pulse Modulation**.

### A. Bpp = 1 (600x600 DPI)
In 1-bit mode, each pixel in the print stream is represented by exactly 1 bit (`0` for off/white, `1` for on/black).

To represent shades of gray, the computer performs **Halftoning (Dithering)**:
* To print **light gray**, the computer tells the printer to print only 10% of the dots in that area, leaving 90% white.
* To print **dark gray**, it prints 80% of the dots.
* Because the dots are extremely small (1/600th of an inch), the human eye cannot distinguish the individual black dots and blends them together, perceiving a smooth shade of gray.

The computer does 100% of this math. The printer simply prints the binary dots as instructed.

### B. Bpp = 2 (1200x600 DPI / FastRes 1200)
In 2-bit mode, each pixel is represented by 2 bits, yielding 4 possible states: `00`, `01`, `10`, and `11`. 

To represent 4 states using binary black toner, the printer controller uses **Pulse-Width Modulation** (turning the laser on for a fraction of a pixel's width):
* **`00`** = Laser is completely **OFF** (White).
* **`01`** = Laser turns on for only **1/3** of the pixel's duration, creating a tiny micro-dot (perceived as light gray).
* **`10`** = Laser turns on for **2/3** of the pixel's duration, creating a medium-sized dot (perceived as medium gray).
* **`11`** = Laser is **ON** for the entire pixel duration (Solid Black).

This hardware technology (HP's **REt - Resolution Enhancement technology** or **FastRes**) allows the printer to paint sub-pixel details. The Mac uses these 2 bits to tell the printer to paint micro-dots of varying widths, enabling sharper text, smoother diagonal lines, and richer gray gradients.
