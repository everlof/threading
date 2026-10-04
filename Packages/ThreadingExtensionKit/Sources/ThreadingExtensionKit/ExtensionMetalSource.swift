import Foundation

/// The same host-owned fullscreen vertex stage and scalar ABI on Mac and phone.
public enum ExtensionMetalSource {
    private static let maximumInputs = 8
    private static let hostVertexFunction = "threadingHostSurfaceVertex"
    private static let hostFragmentFunction = "threadingHostSurfaceFragment"
    private static let imageTextureIndex = 0
    private static let imageSamplerIndex = 0

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
        return """
        #include <metal_stdlib>
        using namespace metal;

        struct ThreadingSurfaceUniforms {
            float2 size;
            float time;
            float _padding;
            float values[\(maximumInputs)];
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
