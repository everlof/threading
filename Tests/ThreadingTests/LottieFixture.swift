import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Threading

/// Documents the media tests can hand a renderer.
///
/// Written by hand rather than checked in as binaries: every one of them is small, and a fixture
/// whose bytes are visible in the diff is a fixture whose *point* is visible in the diff — which
/// matters most for the ones that are deliberately malformed.
enum LottieFixture {

    /// A 100×100 composition at 30fps: one shape layer holding a filled circle that travels from
    /// the upper-left quarter to the lower-right one over one second.
    static func spinningDot(withExpression: Bool = false) -> Data {
        let position: [String: Any] = withExpression
            ? [
                "a": 0,
                "k": [25, 25],
                // The scripting surface. A renderer that evaluated this would be running the
                // document's code; this one reads the static value and says so.
                "x": "var $bm_rt = time * 20;"
            ]
            : [
                "a": 1,
                "k": [
                    [
                        "t": 0,
                        "s": [25, 25],
                        "e": [75, 75],
                        "o": ["x": [0.33], "y": [0]],
                        "i": ["x": [0.67], "y": [1]]
                    ],
                    ["t": 30, "s": [75, 75]]
                ]
            ]

        let document: [String: Any] = [
            "v": "5.7.4",
            "fr": 30,
            "ip": 0,
            "op": 30,
            "w": 100,
            "h": 100,
            "nm": "dot",
            "assets": [],
            "layers": [
                [
                    "ddd": 0,
                    "ind": 1,
                    "ty": 4,
                    "nm": "dot",
                    "sr": 1,
                    "ks": [
                        "o": ["a": 0, "k": 100],
                        "r": ["a": 0, "k": 0],
                        "p": position,
                        "a": ["a": 0, "k": [0, 0]],
                        "s": ["a": 0, "k": [100, 100]]
                    ],
                    "ao": 0,
                    "shapes": [
                        [
                            "ty": "gr",
                            "nm": "group",
                            "it": [
                                [
                                    "ty": "el",
                                    "p": ["a": 0, "k": [0, 0]],
                                    "s": ["a": 0, "k": [20, 20]]
                                ],
                                [
                                    "ty": "fl",
                                    "c": ["a": 0, "k": [1, 0, 0, 1]],
                                    "o": ["a": 0, "k": 100],
                                    "r": 1
                                ],
                                [
                                    "ty": "tr",
                                    "p": ["a": 0, "k": [0, 0]],
                                    "a": ["a": 0, "k": [0, 0]],
                                    "s": ["a": 0, "k": [100, 100]],
                                    "r": ["a": 0, "k": 0],
                                    "o": ["a": 0, "k": 100]
                                ]
                            ]
                        ]
                    ],
                    "ip": 0,
                    "op": 30,
                    "st": 0
                ]
            ]
        ]
        return encode(document)
    }

    /// The same composition with an image layer whose asset is either embedded as base64 or
    /// named as a file beside the document.
    static func withImageAsset(embedded: Bool) -> Data {
        var document = decode(spinningDot())
        let payload = embedded
            ? "data:image/png;base64,\(onePixelPNGBase64)"
            : "dot.png"
        document["assets"] = [
            [
                "id": "image_0",
                "w": 1,
                "h": 1,
                "u": embedded ? "" : "images/",
                "p": payload,
                "e": embedded ? 1 : 0
            ]
        ]
        var layers = document["layers"] as? [[String: Any]] ?? []
        layers.append([
            "ddd": 0,
            "ind": 2,
            "ty": 2,
            "refId": "image_0",
            "nm": "picture",
            "sr": 1,
            "ks": ["o": ["a": 0, "k": 100], "p": ["a": 0, "k": [50, 50]]],
            "ip": 0,
            "op": 30,
            "st": 0
        ])
        document["layers"] = layers
        return encode(document)
    }

    static func withTextLayer() -> Data {
        var document = decode(spinningDot())
        var layers = document["layers"] as? [[String: Any]] ?? []
        layers.append([
            "ddd": 0,
            "ind": 2,
            "ty": 5,
            "nm": "caption",
            "sr": 1,
            "ks": ["o": ["a": 0, "k": 100]],
            "t": ["d": ["k": []]],
            "ip": 0,
            "op": 30,
            "st": 0
        ])
        document["layers"] = layers
        return encode(document)
    }

    // MARK: - Shapes real documents use

    /// A rectangle filled with an **animated** gradient ramp.
    ///
    /// Bodymovin writes a moving gradient as keyframes whose value is the whole flattened ramp.
    /// Reading only the first one drew a blank rectangle for every gradient whose colours move —
    /// caught by a corpus of real animations, guarded here.
    static func animatedGradient() -> Data {
        var document = decode(spinningDot())
        document["layers"] = [shapeLayer(items: [
            [
                "ty": "rc",
                "s": ["a": 0, "k": [80, 80]],
                "p": ["a": 0, "k": [0, 0]],
                "r": ["a": 0, "k": 0]
            ],
            [
                "ty": "gf",
                "t": 1,
                "o": ["a": 0, "k": 100],
                "s": ["a": 0, "k": [-40, 0]],
                "e": ["a": 0, "k": [40, 0]],
                "g": [
                    "p": 2,
                    "k": [
                        "a": 1,
                        "k": [
                            ["t": 0, "s": [0, 1, 0, 0, 1, 0, 0, 1]],
                            ["t": 30, "s": [0, 0, 0, 1, 1, 1, 1, 0]]
                        ]
                    ]
                ]
            ]
        ])]
        return encode(document)
    }

    /// A stroked ellipse painted with a gradient — the loading-spinner idiom.
    static func gradientStroke() -> Data {
        var document = decode(spinningDot())
        document["layers"] = [shapeLayer(items: [
            [
                "ty": "el",
                "s": ["a": 0, "k": [60, 60]],
                "p": ["a": 0, "k": [0, 0]]
            ],
            [
                "ty": "gs",
                "t": 1,
                "o": ["a": 0, "k": 100],
                "w": ["a": 0, "k": 8],
                "lc": 2,
                "lj": 2,
                "s": ["a": 0, "k": [-30, 0]],
                "e": ["a": 0, "k": [30, 0]],
                "g": ["p": 2, "k": ["a": 0, "k": [0, 1, 0, 0, 1, 0, 0, 1]]]
            ]
        ])]
        return encode(document)
    }

    /// A fill whose opacity is keyframed and *labelled static*.
    ///
    /// Real exporters ship `"a": 0` beside a keyframe array. Trusting the flag read the property
    /// as its fallback — zero — so the layer never drew at all.
    static func mislabelledKeyframes() -> Data {
        var document = decode(spinningDot())
        document["layers"] = [shapeLayer(items: [
            [
                "ty": "rc",
                "s": ["a": 0, "k": [80, 80]],
                "p": ["a": 0, "k": [0, 0]],
                "r": ["a": 0, "k": 0]
            ],
            [
                "ty": "fl",
                "c": ["a": 0, "k": [0, 1, 0, 1]],
                // The lie: animated keyframes under a static flag.
                "o": ["a": 0, "k": [["s": 0, "t": 0, "h": 1], ["s": 100, "t": 10]]],
                "r": 1
            ]
        ])]
        return encode(document)
    }

    /// A precomposition placed at a start time, the way a staggered document repeats one asset.
    ///
    /// `ip`/`op` are composition time and `st` shifts only the layer's *own* clock; testing
    /// visibility against the shifted clock made every staggered copy invisible forever.
    static func staggeredPrecomp(startFrame: Double = 10) -> Data {
        var document = decode(spinningDot())
        let inner = shapeLayer(items: [
            [
                "ty": "rc",
                "s": ["a": 0, "k": [60, 60]],
                "p": ["a": 0, "k": [0, 0]],
                "r": ["a": 0, "k": 0]
            ],
            ["ty": "fl", "c": ["a": 0, "k": [0, 0, 1, 1]], "o": ["a": 0, "k": 100], "r": 1]
        ])
        document["assets"] = [["id": "comp_0", "layers": [inner]]]
        document["layers"] = [[
            "ddd": 0,
            "ind": 1,
            "ty": 0,
            "refId": "comp_0",
            "nm": "staggered",
            "sr": 1,
            "w": 100,
            "h": 100,
            "ks": [
                "o": ["a": 0, "k": 100],
                "r": ["a": 0, "k": 0],
                "p": ["a": 0, "k": [50, 50]],
                "a": ["a": 0, "k": [50, 50]],
                "s": ["a": 0, "k": [100, 100]]
            ],
            "ip": startFrame,
            "op": 30,
            "st": startFrame
        ]]
        return encode(document)
    }

    private static func shapeLayer(items: [[String: Any]]) -> [String: Any] {
        [
            "ddd": 0,
            "ind": 1,
            "ty": 4,
            "nm": "shape",
            "sr": 1,
            "ks": [
                "o": ["a": 0, "k": 100],
                "r": ["a": 0, "k": 0],
                "p": ["a": 0, "k": [50, 50]],
                "a": ["a": 0, "k": [0, 0]],
                "s": ["a": 0, "k": [100, 100]]
            ],
            "ao": 0,
            "shapes": [[
                "ty": "gr",
                "nm": "group",
                "it": items + [[
                    "ty": "tr",
                    "p": ["a": 0, "k": [0, 0]],
                    "a": ["a": 0, "k": [0, 0]],
                    "s": ["a": 0, "k": [100, 100]],
                    "r": ["a": 0, "k": 0],
                    "o": ["a": 0, "k": 100]
                ]]
            ]],
            "ip": 0,
            "op": 30,
            "st": 0
        ]
    }

    /// A composition of `count` filled shape layers, each with its own animated transform.
    ///
    /// The stress shape: a real document's cost is layers × frames, and a renderer that is fine
    /// on one circle can be hopeless on the two hundred a designer actually ships.
    static func manyLayers(count: Int, side: Int = 512) -> Data {
        var document = decode(spinningDot())
        document["w"] = side
        document["h"] = side
        document["op"] = 60
        document["layers"] = (0..<count).map { stressLayer(index: $0, of: count, side: side) }
        return encode(document)
    }

    /// Split out of `manyLayers` because one literal holding a whole layer defeats the type
    /// checker — the error is a timeout rather than a mistake, which is its own kind of confusing.
    private static func stressLayer(index: Int, of count: Int, side: Int) -> [String: Any] {
        let phase = Double(index) / Double(max(count, 1))
        let rotation: [String: Any] = [
            "a": 1,
            "k": [
                [
                    "t": 0,
                    "s": [0],
                    "e": [360],
                    "o": ["x": [0.33], "y": [0]],
                    "i": ["x": [0.67], "y": [1]]
                ],
                ["t": 60, "s": [360]]
            ]
        ]
        let travel: [String: Any] = [
            "a": 1,
            "k": [
                ["t": 0, "s": [phase * Double(side), 20]],
                ["t": 60, "s": [phase * Double(side), Double(side) - 20]]
            ]
        ]
        let transform: [String: Any] = [
            "o": ["a": 0, "k": 100],
            "r": rotation,
            "p": travel,
            "a": ["a": 0, "k": [0, 0]],
            "s": ["a": 0, "k": [100, 100]]
        ]
        let items: [[String: Any]] = [
            [
                "ty": "rc",
                "s": ["a": 0, "k": [24, 24]],
                "p": ["a": 0, "k": [0, 0]],
                "r": ["a": 0, "k": 4]
            ],
            [
                "ty": "fl",
                "c": ["a": 0, "k": [phase, 1 - phase, 0.5, 1]],
                "o": ["a": 0, "k": 100],
                "r": 1
            ],
            [
                "ty": "st",
                "c": ["a": 0, "k": [0, 0, 0, 1]],
                "o": ["a": 0, "k": 100],
                "w": ["a": 0, "k": 2],
                "lc": 2,
                "lj": 2
            ],
            [
                "ty": "tr",
                "p": ["a": 0, "k": [0, 0]],
                "a": ["a": 0, "k": [0, 0]],
                "s": ["a": 0, "k": [100, 100]],
                "r": ["a": 0, "k": 0],
                "o": ["a": 0, "k": 100]
            ]
        ]
        return [
            "ddd": 0,
            "ind": index + 1,
            "ty": 4,
            "nm": "layer-\(index)",
            "sr": 1,
            "ks": transform,
            "ao": 0,
            "shapes": [["ty": "gr", "nm": "group", "it": items]],
            "ip": 0,
            "op": 60,
            "st": 0
        ]
    }

    // MARK: - Containers

    /// A `.lottie` container: manifest, one animation, one image.
    ///
    /// `includeTraversalEntry` writes an entry named `../escape.json`, which no honest archiver
    /// produces — the app's own `ZipArchive` sanitizes such a name away, which is exactly why the
    /// fixture writes the record by hand.
    static func dotLottie(includeTraversalEntry: Bool = false) throws -> Data {
        var entries: [(String, Data)] = [
            ("manifest.json", encode([
                "version": "1.0",
                "animations": [["id": "dot"]]
            ])),
            ("animations/dot.json", spinningDot()),
            ("images/dot.png", Data(base64Encoded: onePixelPNGBase64) ?? Data())
        ]
        if includeTraversalEntry {
            entries.append(("../escape.json", Data("{}".utf8)))
        }
        return storedZip(entries)
    }

    // MARK: - Animated images

    static func animatedGIF(frames: Int, delay: Double, side: Int = 32) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.gif.identifier as CFString,
            frames,
            nil
        ) else { return nil }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        for step in 0..<frames {
            guard let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(
                red: CGFloat(step) / CGFloat(max(frames - 1, 1)),
                green: 0.2,
                blue: 0.6,
                alpha: 1
            )
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            guard let frame = context.makeImage() else { return nil }
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Primitives

    /// A 1×1 transparent PNG, small enough to inline and real enough to decode.
    static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
        + "+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

    static func encode(_ object: [String: Any]) -> Data {
        // swiftlint:disable:next force_try - the fixture's own literals are always encodable.
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// A stored (uncompressed) ZIP, written by hand so a fixture can put a name in it that the
    /// app's own writer would refuse.
    static func storedZip(_ entries: [(String, Data)]) -> Data {
        var payload = Data()
        var directory = Data()
        var offsets: [Int] = []

        for (name, bytes) in entries {
            offsets.append(payload.count)
            let nameBytes = Data(name.utf8)
            let checksum = ZipArchive.crc32(bytes)

            payload.append(uint32(0x0403_4B50))
            payload.append(uint16(20))
            payload.append(uint16(0))
            payload.append(uint16(0))
            payload.append(uint16(0))
            payload.append(uint16(0))
            payload.append(uint32(checksum))
            payload.append(uint32(UInt32(bytes.count)))
            payload.append(uint32(UInt32(bytes.count)))
            payload.append(uint16(UInt16(nameBytes.count)))
            payload.append(uint16(0))
            payload.append(nameBytes)
            payload.append(bytes)
        }

        for (index, entry) in entries.enumerated() {
            let nameBytes = Data(entry.0.utf8)
            let checksum = ZipArchive.crc32(entry.1)

            directory.append(uint32(0x0201_4B50))
            directory.append(uint16(20))
            directory.append(uint16(20))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint32(checksum))
            directory.append(uint32(UInt32(entry.1.count)))
            directory.append(uint32(UInt32(entry.1.count)))
            directory.append(uint16(UInt16(nameBytes.count)))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint32(0))
            directory.append(uint32(UInt32(offsets[index])))
            directory.append(nameBytes)
        }

        var archive = payload
        let directoryOffset = archive.count
        archive.append(directory)
        archive.append(uint32(0x0605_4B50))
        archive.append(uint16(0))
        archive.append(uint16(0))
        archive.append(uint16(UInt16(entries.count)))
        archive.append(uint16(UInt16(entries.count)))
        archive.append(uint32(UInt32(directory.count)))
        archive.append(uint32(UInt32(directoryOffset)))
        archive.append(uint16(0))
        return archive
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}
