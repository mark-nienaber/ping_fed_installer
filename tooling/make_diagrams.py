#!/usr/bin/env python3
"""Generate the installer README diagrams as SVG, then render PNGs for GitHub.

    python3 tooling/make_diagrams.py

SVG sources and rendered PNGs both land in docs/images/. PNGs are what the README
and the blog embed. Rendering needs rsvg-convert (librsvg); if it is missing, the
SVGs are still written and a warning is printed.

Arrowheads use marker orient="auto" (see svgkit.render) so every rasterizer draws
them pointing along the line — auto-start-reverse is mishandled by some renderers
and prints the arrowhead rotated sideways.
"""
import sys, pathlib, shutil, subprocess

HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE))
import svgkit  # noqa: E402
import diagrams  # noqa: E402

OUT = HERE.parent / "docs/images"
PNG_WIDTH = 2000  # 2x for crisp rendering on high-DPI displays

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    svgs = diagrams.build(OUT)
    print(f"{len(svgs)} diagrams written")

    if svgkit.PROBLEMS:
        print("\nLAYOUT PROBLEMS")
        for name, problems in svgkit.PROBLEMS:
            print(f"  {name}")
            for p in problems:
                print(f"    - {p}")
        sys.exit(1)
    print("layout audit clean")

    rsvg = shutil.which("rsvg-convert")
    if not rsvg:
        print("WARNING: rsvg-convert not found — PNGs not rendered. "
              "Install librsvg2-tools to embed images in the README.")
        sys.exit(0)
    for svg in svgs:
        png = svg.with_suffix(".png")
        subprocess.run([rsvg, "-w", str(PNG_WIDTH), str(svg), "-o", str(png)], check=True)
    print(f"{len(svgs)} PNGs rendered at {PNG_WIDTH}px")
