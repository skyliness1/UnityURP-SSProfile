#ifndef SOUL_SSS_PROFILE_SAMPLING_INCLUDE
#define SOUL_SSS_PROFILE_SAMPLING_INCLUDE

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "SSProfileCommon.hlsl"

// ============================================================================
// 全局纹理（由 RenderFeature 绑定）
// ============================================================================

TEXTURE2D(_SubsurfaceProfileTexture);
SAMPLER(sampler_SubsurfaceProfileTexture);
float4 _SubsurfaceProfileTexture_TexelSize; // (width, height, 1/width, 1/height)

// ============================================================================
// Profile 参数结构
// ============================================================================

struct SSProfileParams
{
    float3 tint;
    float  worldUnitScale;
    
    float3 surfaceAlbedo;
    float  surfaceAlbedoMax;
    
    float3 diffuseMeanFreePath;
    float  diffuseMeanFreePathMax;
    
    float  extinctionScale;
    float  normalScale;
    float  scatteringDistribution;
    float  ior;
    
    float3 boundaryColorBleed;
    
    float  roughness0;
    float  roughness1;
    float  lobeMix;
    float  avgRoughness;
};

// ============================================================================
// Profile LUT 采样
// ============================================================================

float4 SampleProfileTexture(uint profileID, uint offset)
{
    float u = (float(offset) + 0.5) * _SubsurfaceProfileTexture_TexelSize.z;
    float v = (float(profileID) + 0.5) * _SubsurfaceProfileTexture_TexelSize.w;
    return SAMPLE_TEXTURE2D_LOD(_SubsurfaceProfileTexture, sampler_SubsurfaceProfileTexture, float2(u, v), 0);
}

SSProfileParams LoadSSProfileParams(uint profileID)
{
    SSProfileParams params;
    
    // [0] Tint + WorldUnitScale
    float4 tintScale = SampleProfileTexture(profileID, SSSS_TINT_SCALE_OFFSET);
    params.tint = tintScale.rgb;
    params.worldUnitScale = DecodeWorldUnitScale(tintScale.a);
    
    // [1] Surface Albedo
    float4 albedo = SampleProfileTexture(profileID, BSSS_SURFACEALBEDO_OFFSET);
    params.surfaceAlbedo = albedo.rgb;
    params.surfaceAlbedoMax = albedo.a;
    
    // [2] Diffuse Mean Free Path
    float4 dmfpEncoded = SampleProfileTexture(profileID, BSSS_DMFP_OFFSET);
    params.diffuseMeanFreePath = DecodeDiffuseMeanFreePath(dmfpEncoded.rgb);
    params.diffuseMeanFreePathMax = DecodeDiffuseMeanFreePath(dmfpEncoded.a);
    
    // [3] Transmission Params
    float4 transParams = SampleProfileTexture(profileID, SSSS_TRANSMISSION_OFFSET);
    params.extinctionScale = DecodeExtinctionScale(transParams.r);
    params.normalScale = transParams.g;
    params.scatteringDistribution = DecodeScatteringDistribution(transParams.b);
    params.ior = 1.0 / transParams.a;
    
    // [4] Boundary Color Bleed
    float4 boundary = SampleProfileTexture(profileID, SSSS_BOUNDARY_COLOR_BLEED_OFFSET);
    params.boundaryColorBleed = boundary.rgb;
    
    // [5] Dual Specular
    float4 dualSpec = SampleProfileTexture(profileID, SSSS_DUAL_SPECULAR_OFFSET);
    
    float2 roughness = DecodeDualSpecularRoughness(dualSpec.rg);
    params.roughness0 = roughness.x;
    params.roughness1 = roughness.y;
    params.lobeMix = dualSpec.b;
    
    params.avgRoughness = DecodeSingleRoughness(dualSpec.a);
    
    return params;
}

#endif