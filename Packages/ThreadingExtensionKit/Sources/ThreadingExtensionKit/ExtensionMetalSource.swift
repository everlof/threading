import Foundation

/// The same host-owned fullscreen vertex stage and scalar ABI on Mac and phone.
///
/// Every host renderer binds `ThreadingSurfaceUniforms` at fragment buffer 0 as a flat run of
/// 32-bit floats laid out by `UniformLayout`, so the struct a shader is compiled against and the
/// floats a renderer uploads cannot drift apart: both read the numbers stated here.
public enum ExtensionMetalSource {
    private static let hostVertexFunction = "threadingHostSurfaceVertex"
    private static let hostFragmentFunction = "threadingHostSurfaceFragment"
    private static let imageTextureIndex = 0
    private static let imageSamplerIndex = 0

    /// `ThreadingSurfaceUniforms` as Metal lays it out, counted in 4-byte floats:
    ///
    /// | Field             | Floats | Bytes  |
    /// |-------------------|--------|--------|
    /// | `float2 size`     | 0…1    | 0…7    |
    /// | `float time`      | 2      | 8…11   |
    /// | `float _padding`  | 3      | 12…15  |
    /// | `float values[8]` | 4…11   | 16…47  |
    /// | `float4 focus[2]` | 12…19  | 48…79  |
    ///
    /// `focus` begins at byte 48, a multiple of a `float4`'s 16-byte alignment, so Metal inserts
    /// no padding before it, and the struct is exactly 80 bytes with no tail padding. Each focus
    /// region is `(x, y, width, height)` in the fragment's own `uv` space — origin at the
    /// surface's top-left corner, y downward, `0…1` across the surface — and a width of zero
    /// means the region does not exist. See `FocusRegion` for which slot holds what.
    public enum UniformLayout {
        /// The scalar inputs a surface may declare (`values[8]`).
        public static let maximumInputs = 8
        /// The regions a placement may state (`focus[2]`).
        public static let focusRegionCount = FocusRegion.allCases.count
        /// Floats per focus region: `(x, y, width, height)`.
        public static let floatsPerFocusRegion = 4
        /// The first float of `values`.
        public static let valuesOffset = 4
        /// The first float of `focus`.
        public static let focusOffset = valuesOffset + maximumInputs
        /// Floats in the whole struct.
        public static let floatCount = focusOffset + focusRegionCount * floatsPerFocusRegion
        /// Bytes in the whole struct: the length every renderer binds at fragment buffer 0.
        public static let byteCount = floatCount * MemoryLayout<Float>.size
        /// The byte offset of `focus`, which reflection of a compiled shader reports.
        public static let focusByteOffset = focusOffset * MemoryLayout<Float>.size
    }

    /// Which region each `focus` slot holds. A placement that states none uploads zeros.
    public enum FocusRegion: Int, CaseIterable, Sendable {
        /// `focus[0]`: at `composer.backdrop@1`, the composer's hero — its mark over the
        /// greeting; zero while the hero is hidden.
        case primary = 0
        /// `focus[1]`: at `composer.backdrop@1`, the composer's prompt box.
        case secondary = 1
    }

    public static func completeSource(
        extensionSource: String,
        fragmentFunction: String,
        isTextured: Bool
    ) -> String {
        let fragmentWrapper = isTextured
            ? """
            fragment float4 \(hostFragmentFunction)(
                ThreadingSurfaceVertexOut in [[stage_in]],
                constant ThreadingSurfaceUniforms &uniforms [[buffer(0)]],
                texture2d<float> image [[texture(\(imageTextureIndex))]],
                sampler imageSampler [[sampler(\(imageSamplerIndex))]]
            ) {
                return \(fragmentFunction)(in.uv, uniforms, image, imageSampler);
            }
            """
            : """
            fragment float4 \(hostFragmentFunction)(
                ThreadingSurfaceVertexOut in [[stage_in]],
                constant ThreadingSurfaceUniforms &uniforms [[buffer(0)]]
            ) {
                return \(fragmentFunction)(in.uv, uniforms);
            }
            """
        // The vertex stage maps clip space onto `uv` with x rightward and y downward: clip
        // (-1, 1), the top-left corner, is uv (0, 0) and clip (1, -1) is uv (1, 1). The focus
        // regions are stated in that same space, which is also a texture's: `image.sample`
        // at `uv` reads the picture upright.
        return """
        #include <metal_stdlib>
        using namespace metal;

        struct ThreadingSurfaceUniforms {
            float2 size;
            float time;
            float _padding;
            float values[\(UniformLayout.maximumInputs)];
            float4 focus[\(UniformLayout.focusRegionCount)];
        };

        struct ThreadingSurfaceVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex ThreadingSurfaceVertexOut \(hostVertexFunction)(uint vertexID [[vertex_id]]) {
            const float2 positions[3] = {
                float2(-1.0, -1.0),
                float2( 3.0, -1.0),
                float2(-1.0,  3.0)
            };
            ThreadingSurfaceVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = positions[vertexID] * float2(0.5, -0.5) + 0.5;
            return out;
        }

        \(extensionSource)

        \(fragmentWrapper)
        """
    }
}
