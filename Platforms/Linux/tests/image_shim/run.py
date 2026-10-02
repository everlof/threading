#!/usr/bin/env python3
"""Build the narrow drawing leaf in an isolated directory; never touches SwiftPM's .build."""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[4]
shim = root / "Platforms/Linux/Sources/AppKit"
evidence = root / "Platforms/Linux/out/image-interpolation"
evidence.mkdir(parents=True, exist_ok=True)


def pixels(output: str) -> dict[str, list[tuple[int, ...]]]:
    result = {}
    for line in output.splitlines():
        label, *values = line.split()
        if label == "raw":
            continue
        result[label] = [tuple(map(int, value.split(":", 1)[1].split(","))) for value in values]
    return result


with tempfile.TemporaryDirectory(prefix="threading-image-shim-") as folder:
    output = Path(folder)
    extension = "dylib" if platform.system() == "Darwin" else "so"
    sources = [shim / name for name in ["Exports.swift", "Geometry.swift", "NSColor.swift", "NSBezierPath.swift",
                                      "Raster.swift", "RasterClip.swift", "NSGraphicsContext.swift", "NSImage.swift",
                                      "ImageCompositing.swift", "PNG.swift"]]
    sources.append(Path(__file__).with_name("FixtureDependencies.swift"))
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(output / "module-cache"), "-emit-library", "-emit-module",
                    "-module-name", "AppKit", "-emit-module-path", str(output / "AppKit.swiftmodule"),
                    "-o", str(output / f"libAppKit.{extension}"), *map(str, sources)], check=True)
    binary = output / "contracts"
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(output / "module-cache"), "-parse-as-library", "-I", str(output),
                    "-L", str(output), "-lAppKit", "-Xlinker", "-rpath", "-Xlinker", str(output),
                    str(root / "Sources/Threading/UI/Design/TemplateImageDrawing.swift"),
                    str(Path(__file__).with_name("Contracts.swift")), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

    interpolation = output / "interpolation"
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(output / "module-cache"),
                    "-parse-as-library", "-I", str(output), "-L", str(output), "-lAppKit",
                    "-Xlinker", "-rpath", "-Xlinker", str(output),
                    str(Path(__file__).with_name("InterpolationContracts.swift")), "-o", str(interpolation)], check=True)
    shim_output = subprocess.run([str(interpolation), str(evidence)], check=True,
                                 capture_output=True, text=True).stdout
    print(shim_output, end="")
    if platform.system() == "Darwin":
        mac_probe = output / "mac-interpolation"
        subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(output / "mac-module-cache"),
                        "-parse-as-library", str(Path(__file__).with_name("MacInterpolationProbe.swift")),
                        "-o", str(mac_probe)], check=True)
        mac_output = subprocess.run([str(mac_probe), str(evidence)], check=True,
                                    capture_output=True, text=True).stdout
        print(mac_output, end="")
        shim_pixels, mac_pixels = pixels(shim_output), pixels(mac_output)
        assert shim_pixels.keys() == mac_pixels.keys()
        for label in ["none", "contextNone", "contextHighNoneHint", "zeroSource", "sourceCrop", "copyHalf"]:
            assert shim_pixels[label] == mac_pixels[label], (label, shim_pixels[label], mac_pixels[label])
        for label in ["high", "highRaw", "contextNoneHighHint"]:
            assert max(abs(a - b) for shim_point, mac_point in zip(shim_pixels[label], mac_pixels[label])
                       for a, b in zip(shim_point, mac_point)) <= 25, label
        # AppKit's high downsampler on this 8×8 checker yields 165 where the shim's bounded
        # 4×4 area sampling yields 128. Keep the render in evidence without pretending its
        # filter is pixel-identical; both avoid the nearest-neighbor alias pattern.
        assert all(120 <= channel <= 170 for channel in shim_pixels["downsample"][8][:3])
        assert all(120 <= channel <= 170 for channel in mac_pixels["downsample"][8][:3])
        assert shim_pixels["high"] != shim_pixels["none"]
        assert shim_pixels["highRaw"] == shim_pixels["high"] == shim_pixels["contextNoneHighHint"]
        assert shim_pixels["none"] == shim_pixels["contextNone"] == shim_pixels["contextHighNoneHint"]
        assert shim_pixels["none"] == shim_pixels["zeroSource"]
        print("PASS image interpolation: real AppKit exact nearest/crop/copy and bounded high-quality behavior")
    else:
        shim_pixels = pixels(shim_output)
        assert shim_pixels["high"] != shim_pixels["none"]
        assert shim_pixels["highRaw"] == shim_pixels["high"] == shim_pixels["contextNoneHighHint"]
        assert shim_pixels["none"] == shim_pixels["contextNone"] == shim_pixels["contextHighNoneHint"]
        assert shim_pixels["none"] == shim_pixels["zeroSource"]
        print("PASS image interpolation: nearest/crop/copy and graphics-state hint precedence")
    print(f"Image evidence: {evidence}")
