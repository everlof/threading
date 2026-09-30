#!/usr/bin/env python3
"""Build the narrow drawing leaf in an isolated directory; never touches SwiftPM's .build."""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[4]
shim = root / "Spikes/linux-appkit/Sources/AppKit"
with tempfile.TemporaryDirectory(prefix="threading-image-shim-") as folder:
    output = Path(folder)
    extension = "dylib" if platform.system() == "Darwin" else "so"
    sources = [shim / name for name in ["Exports.swift", "Geometry.swift", "NSColor.swift", "NSBezierPath.swift",
                                      "Raster.swift", "NSGraphicsContext.swift", "NSImage.swift", "ImageCompositing.swift"]]
    if platform.system() == "Darwin":
        sources.append(root / "Spikes/linux-appkit/tests/raster_bounds/HostGeometry.swift")
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(output / "module-cache"), "-emit-library", "-emit-module",
                    "-module-name", "AppKit", "-emit-module-path", str(output / "AppKit.swiftmodule"),
                    "-o", str(output / f"libAppKit.{extension}"), *map(str, sources)], check=True)
    binary = output / "contracts"
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(output / "module-cache"), "-parse-as-library", "-I", str(output),
                    "-L", str(output), "-lAppKit", "-Xlinker", "-rpath", "-Xlinker", str(output),
                    str(root / "Sources/Threading/UI/Design/TemplateImageDrawing.swift"),
                    str(Path(__file__).with_name("Contracts.swift")), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
