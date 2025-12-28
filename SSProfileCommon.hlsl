#ifndef SSPROFILE_COMMON_INCLUDED
#define SSPROFILE_COMMON_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "SSProfileDefines.hlsl"

// ============================================================================
// 基础采样
// ============================================================================
float4 LoadSSProfileTexture(uint profileId, uint pixelOffset)
{
    return LOAD_TEXTURE2D(_SSProfilesTexture, int2(pixelOffset, profileId));
}

float4 SampleSSProfileTexture(uint profileId, uint pixelOffset)
{
    float2 uv = float2(
        (pixelOffset + 0.5) * _SSProfilesTextureSize. z,
        (profileId + 0.5) * _SSProfilesTextureSize.w
    );
    return SAMPLE_TEXTURE2D_LOD(_SSProfilesTexture, sampler_SSProfilesTexture, uv, 0);
}

// ============================================================================
// 解码函数
// ============================================================================
float DecodeWorldUnitScale(float encoded)
{
    return encoded * DEC_UNIT_TO_WORLDUNITSCALE_IN_CM;
}

float4 DecodeDiffuseMeanFreePath(float4 encoded)
{
    return encoded * DEC_UNIT_TO_DIFFUSEMEANFREEPATH_IN_MM;
}

float DecodeExtinctionScale(float encoded)
{
    return encoded * DEC_EXTINCTIONSCALE_FACTOR;
}

float DecodeScatteringDistribution(float encoded)
{
    return encoded * 2.0 - 1.0;
}

float DecodeDualSpecularRoughness(float encoded)
{
    return encoded * SSSS_MAX_DUAL_SPECULAR_ROUGHNESS;
}

// ============================================================================
// 数据获取函数
// ============================================================================
void GetSubsurfaceProfileTintAndScale(uint profileId, out float3 tint, out float worldUnitScale)
{
    float4 data = LoadSSProfileTexture(profileId, SSSS_TINT_SCALE_OFFSET);
    tint = data.rgb;
    worldUnitScale = DecodeWorldUnitScale(data.a);
}

float4 GetSubsurfaceProfileSurfaceAlbedo(uint profileId)
{
    return LoadSSProfileTexture(profileId, BSSS_SURFACEALBEDO_OFFSET);
}

float4 GetSubsurfaceProfileDMFP(uint profileId)
{
    return DecodeDiffuseMeanFreePath(LoadSSProfileTexture(profileId, BSSS_DMFP_OFFSET));
}

void GetSubsurfaceProfileTransmissionParams(uint profileId,
    out float extinctionScale, out float normalScale,
    out float scatteringDistribution, out float oneOverIOR)
{
    float4 data = LoadSSProfileTexture(profileId, SSSS_TRANSMISSION_OFFSET);
    extinctionScale = DecodeExtinctionScale(data.r);
    normalScale = data.g;
    scatteringDistribution = DecodeScatteringDistribution(data.b);
    oneOverIOR = data.a;
}

float3 GetSubsurfaceProfileBoundaryBleed(uint profileId)
{
    return LoadSSProfileTexture(profileId, SSSS_BOUNDARY_COLOR_BLEED_OFFSET).rgb;
}

void GetSubsurfaceProfileDualSpecular(uint profileId,
    out float roughness0, out float roughness1, out float lobeMix)
{
    float4 data = LoadSSProfileTexture(profileId, SSSS_DUAL_SPECULAR_OFFSET);
    roughness0 = DecodeDualSpecularRoughness(data.r);
    roughness1 = DecodeDualSpecularRoughness(data.g);
    lobeMix = data.b;
}

// ============================================================================
// Kernel 采样
// ============================================================================
void GetKernelOffsetAndSize(uint quality, out uint offset, out uint size)
{
    if (quality == 2) // High
    {
        offset = SSSS_KERNEL0_OFFSET;
        size = SSSS_KERNEL0_SIZE;
    }
    else if (quality == 1) // Medium
    {
        offset = SSSS_KERNEL1_OFFSET;
        size = SSSS_KERNEL1_SIZE;
    }
    else // Low
    {
        offset = SSSS_KERNEL2_OFFSET;
        size = SSSS_KERNEL2_SIZE;
    }
}

// 获取 Kernel 采样数据
// 返回:  xyz = 权重, w = 采样偏移
float4 GetSubsurfaceProfileKernelSample(uint profileId, uint quality, uint sampleIndex)
{
    uint offset, size;
    GetKernelOffsetAndSize(quality, offset, size);
    
    if (sampleIndex >= size)
        return float4(0, 0, 0, 0);
    
    float4 data = LoadSSProfileTexture(profileId, offset + sampleIndex);
    
    float3 weight = data.rgb;
    float kernelOffset = data.a * TABLE_MAX_A * SUBSURFACE_RADIUS_SCALE;
    
    return float4(weight, kernelOffset);
}

// ============================================================================
// Transmission Profile 采样
// ============================================================================
float4 SampleTransmissionProfile(uint profileId, float thickness)
{
    float normalizedDist = saturate(thickness / SSSS_MAX_TRANSMISSION_PROFILE_DISTANCE);
    float samplePos = normalizedDist * (BSSS_TRANSMISSION_PROFILE_SIZE - 1);
    
    uint index0 = (uint)samplePos;
    uint index1 = min(index0 + 1, BSSS_TRANSMISSION_PROFILE_SIZE - 1);
    float frac = samplePos - index0;
    
    float4 s0 = LoadSSProfileTexture(profileId, BSSS_TRANSMISSION_PROFILE_OFFSET + index0);
    float4 s1 = LoadSSProfileTexture(profileId, BSSS_TRANSMISSION_PROFILE_OFFSET + index1);
    
    return lerp(s0, s1, frac);
}

// ============================================================================
// Scaling Factor (用于实时计算)
// ============================================================================
float3 GetSearchLightDiffuseScalingFactor3D(float3 albedo)
{
    float3 v = albedo - 0.33;
    return 3.5 + 100.0 * v * v * v * v;
}

float3 GetPerpendicularScalingFactor3D(float3 albedo)
{
    float3 v = abs(albedo - 0.8);
    return 1.85 - albedo + 7.0 * v * v * v;
}

// ============================================================================
// 工具函数
// ============================================================================
uint GetProfileIdFromNormalized(float normalizedId)
{
    return (uint)(normalizedId * 255.0 + 0.5);
}

bool IsValidProfile(uint profileId)
{
    return profileId < 256;
}

#endif // SSPROFILE_COMMON_INCLUDED