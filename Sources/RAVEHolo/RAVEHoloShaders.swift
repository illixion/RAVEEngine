/// Metal source for `RAVEHoloRenderer`, compiled at runtime so the target
/// builds the same under Xcode and plain `swift build` (SwiftPM's command
/// line does not compile `.metal` resources).
///
/// Look: an emitter projecting light, not a lit card. Colour is written
/// premultiplied with alpha below its brightness, so the backing darkens a
/// little while strokes mostly add light; scanlines run across the panel in
/// local metres (fixed pitch at any distance), and a slow per-panel flicker
/// keeps it from reading as a flat decal.
enum RAVEHoloShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct HoloFrame {
        float4x4 viewProjection[2];
        float4 params;          // x = time (s), y = scanline pitch (m), z = scanline depth, w = flicker depth
    };
    struct HoloPanelGPU {
        float4x4 model;
        float4 params;          // x = opacity, y = seed, z = brightness
    };
    struct HoloQuadGPU {
        float4 rect;            // min x, min y, width, height (panel metres)
        float4 params;
        float4 color;
        uint panel;
        uint kind;
        uint pad0;
        uint pad1;
    };

    struct HoloVaryings {
        float4 position [[position]];
        float2 local;           // panel metres
        float2 inQuad;          // quad metres from its min corner
        float2 uv;
        uint quad [[flat]];
    };

    vertex HoloVaryings holoVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   ushort amp [[amplification_id]],
                                   constant HoloFrame &frame [[buffer(0)]],
                                   const device HoloPanelGPU *panels [[buffer(1)]],
                                   const device HoloQuadGPU *quads [[buffer(2)]])
    {
        const float2 corners[6] = { {0, 0}, {1, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 1} };
        const HoloQuadGPU q = quads[iid];
        const float2 c = corners[vid];
        const float2 local = q.rect.xy + c * q.rect.zw;
        HoloVaryings out;
        out.position = frame.viewProjection[amp] * (panels[q.panel].model * float4(local, 0, 1));
        out.local = local;
        out.inQuad = c * q.rect.zw;
        // Atlas v runs top-down; the quad's top (c.y = 1) samples v0.
        out.uv = float2(mix(q.params.x, q.params.z, c.x), mix(q.params.w, q.params.y, c.y));
        out.quad = iid;
        return out;
    }

    static float roundedBox(float2 p, float2 b, float r)
    {
        const float2 d = abs(p) - b + r;
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
    }

    fragment float4 holoFragment(HoloVaryings in [[stage_in]],
                                 constant HoloFrame &frame [[buffer(0)]],
                                 const device HoloPanelGPU *panels [[buffer(1)]],
                                 const device HoloQuadGPU *quads [[buffer(2)]],
                                 texture2d<float> atlas [[texture(0)]])
    {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        const HoloQuadGPU q = quads[in.quad];
        const float2 half_ = q.rect.zw * 0.5;
        const float2 p = in.inQuad - half_;
        const float aa = max(fwidth(in.inQuad.x), fwidth(in.inQuad.y));
        float coverage = 0;
        float glow = 0;
        switch (q.kind) {
        case 0: {   // fill
            const float d = roundedBox(p, half_, q.params.x);
            coverage = 1.0 - smoothstep(-aa, aa, d);
            break;
        }
        case 1: {   // frame
            const float d = roundedBox(p, half_, q.params.x);
            coverage = 1.0 - smoothstep(-aa, aa, abs(d + q.params.y * 0.5) - q.params.y * 0.5);
            glow = (1.0 - smoothstep(0.0, q.params.y * 4.0, abs(d))) * 0.35;
            break;
        }
        case 2: {   // bar: lit up to the fraction, dim beyond; optional segments
            const float t = in.inQuad.x / max(q.rect.z, 1e-5);
            const float segments = q.params.y;
            const float corner = q.params.w;
            float inSeg = 1;
            float lit;
            if (segments > 0.5) {
                const float cell = q.rect.z / segments;
                const float x = fmod(in.inQuad.x, cell);
                const float2 segHalf = float2(max(cell - q.params.z, 1e-5) * 0.5, half_.y);
                inSeg = 1.0 - smoothstep(-aa, aa, roundedBox(float2(x - cell * 0.5, p.y), segHalf,
                                                             min(corner, min(segHalf.x, segHalf.y))));
                // Whole segments: one lights once the fill passes its centre.
                lit = (floor(t * segments) + 0.5) / segments <= q.params.x ? 1.0 : 0.18;
            } else {
                // One rounded gauge; the lit part is rounded the same, so its
                // leading end reads as a capsule, not a cut.
                inSeg = 1.0 - smoothstep(-aa, aa, roundedBox(p, half_, min(corner, min(half_.x, half_.y))));
                const float litHalf = q.rect.z * q.params.x * 0.5;
                const float litMask = litHalf <= 0.0 ? 0.0 :
                    1.0 - smoothstep(-aa, aa, roundedBox(float2(in.inQuad.x - litHalf, p.y), float2(litHalf, half_.y),
                                                         min(corner, min(litHalf, half_.y))));
                lit = mix(0.18, 1.0, litMask);
            }
            coverage = inSeg * lit;
            glow = inSeg * lit * 0.15;
            break;
        }
        default: {  // glyph (SDF, 0.5 on the outline)
            const float d = atlas.sample(linear, in.uv).r - 0.5;
            const float w = max(fwidth(d), 1e-4);
            coverage = smoothstep(-w, w, d);
            glow = smoothstep(-0.30, 0.0, d) * 0.45;
            break;
        }
        }
        const HoloPanelGPU panel = panels[q.panel];
        const float time = frame.params.x;
        const float scan = 1.0 - frame.params.z * (0.5 + 0.5 * sin(in.local.y * (6.2831853 / frame.params.y)));
        const float flicker = 1.0 - frame.params.w * (0.5 + 0.5 * sin(time * 23.0 + panel.params.y * 7.3))
                                                   * (0.5 + 0.5 * sin(time * 3.1 + panel.params.y));
        const float a = saturate(max(coverage, glow)) * q.color.a * panel.params.x * flicker;
        if (a <= 0.002) discard_fragment();
        const float3 rgb = q.color.rgb * scan * (coverage + glow * (1.0 - coverage)) * panel.params.z;
        // Premultiplied; the fill kind carries real alpha (it is the dark
        // backing), everything else adds light over whatever is behind.
        const float occlusion = q.kind == 0 ? a : a * 0.35;
        return float4(rgb * a, occlusion);
    }
    """
}
