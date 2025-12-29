#ifndef SSPROFILE_COMMON_INCLUDED
#define SSPROFILE_COMMON_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SoulGBuffer.hlsl"
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
        (pixelOffset + 0.5) * _SSProfilesTextureSize.z,
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
// Kernel 采样 (修正版)
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

// 获取 Kernel 采样数据 (修正版)
// 返回:  xyz = 权重 (已乘 TABLE_MAX_RGB), w = 采样偏移 (已乘 TABLE_MAX_A)
float4 GetSubsurfaceProfileKernelSample(uint profileId, uint quality, uint sampleIndex)
{
    uint offset, size;
    GetKernelOffsetAndSize(quality, offset, size);
    
    if (sampleIndex >= size)
        return float4(0, 0, 0, 0);
    
    float4 data = LoadSSProfileTexture(profileId, offset + sampleIndex);
    
    // 修正:  
    // - RGB 权重乘以 TABLE_MAX_RGB (实际上是 1.0，所以不变)
    // - A 偏移乘以 TABLE_MAX_A (3.0)
    // - 不再乘以 SUBSURFACE_RADIUS_SCALE (这在编码时已经处理)
    float3 weight = data.rgb * TABLE_MAX_RGB;
    float kernelOffset = data.a * TABLE_MAX_A;
    
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

// ============================================================================
// 光照计算函数
// ============================================================================
bool IsCheckerboardEven(int2 pixelCoord)
{
    return ((pixelCoord.x + pixelCoord.y) & 1) == 0;
}

float3 CalculateDualSpecular(
    BRDFData brdfData,
    float3 normalWS,
    float3 lightDir,
    float3 viewDir,
    float roughness0,
    float roughness1,
    float lobeMix,
    float opacity)
{
    // 当 opacity 较低时，平滑过渡到普通 specular
    // 参考 UE5: SubsurfaceProfileCommon. ush - GetSubsurfaceProfileDualSpecular
    float opacityFade = saturate((opacity - 0.1) * 10.0);
    
    // Lobe 0
    BRDFData brdfData0 = brdfData;
    float r0 = lerp(brdfData.roughness, saturate(roughness0 * brdfData.roughness), opacityFade);
    brdfData0.roughness = r0;
    brdfData0.roughness2 = r0 * r0;
    brdfData0.normalizationTerm = r0 * 4.0 + 2.0;
    brdfData0.roughness2MinusOne = brdfData0.roughness2 - 1.0;
    
    // Lobe 1
    BRDFData brdfData1 = brdfData;
    float r1 = lerp(brdfData.roughness, saturate(roughness1 * brdfData.roughness), opacityFade);
    brdfData1.roughness = r1;
    brdfData1.roughness2 = r1 * r1;
    brdfData1.normalizationTerm = r1 * 4.0 + 2.0;
    brdfData1.roughness2MinusOne = brdfData1.roughness2 - 1.0;
    
    float3 spec0 = DirectBRDFSpecular(brdfData0, normalWS, lightDir, viewDir);
    float3 spec1 = DirectBRDFSpecular(brdfData1, normalWS, lightDir, viewDir);
    
    return lerp(spec0, spec1, lobeMix);
}

// 透射参数结构
struct TransmissionParams
{
    float extinctionScale;
    float normalScale;
    float scatteringDistribution;
    float oneOverIOR;
};

TransmissionParams GetTransmissionParams(uint profileId)
{
    TransmissionParams params;
    GetSubsurfaceProfileTransmissionParams(profileId,
        params.extinctionScale,
        params.normalScale,
        params.scatteringDistribution,
        params.oneOverIOR);
    return params;
}

// 计算透射光照
// 参考 UE5: SeparableSSS.ush - SSSSTransmittance
// 以及 TransmissionCommon. ush
float3 CalculateTransmission(
    uint profileId,
    float3 worldPosition,
    float3 worldNormal,
    float3 lightDir,
    float shadowDepth,        // 从阴影贴图采样的深度
    float receiverDepth,      // 当前像素的深度
    float3 lightColor,
    float lightAttenuation)
{
    TransmissionParams params = GetTransmissionParams(profileId);
    
    // 计算厚度 (光线穿过物体的距离)
    // shadowDepth 是光源视角下遮挡物的深度
    // receiverDepth 是光源视角下当前像素的深度
    float thickness = max(receiverDepth - shadowDepth, 0.0) * params.extinctionScale;
    
    // 从 Transmission Profile 采样
    float4 transmissionProfile = SampleTransmissionProfile(profileId, thickness);
    float3 transmissionColor = transmissionProfile.rgb;
    float shadowFalloff = transmissionProfile.a;
    
    // 计算透射方向
    // 使用法线偏移来模拟光线在物体内部的散射
    float3 transmissionNormal = normalize(worldNormal * params.normalScale - lightDir);
    
    // 背面光照因子
    float NdotL = dot(worldNormal, lightDir);
    float backNdotL = saturate(-NdotL);
    
    // 散射分布 (Henyey-Greenstein 相函数的简化版本)
    float VdotL = dot(normalize(-worldPosition), lightDir); // 假设相机在原点
    float scatter = lerp(backNdotL, saturate(VdotL), params.scatteringDistribution * 0.5 + 0.5);
    
    // 最终透射
    float3 transmission = transmissionColor * shadowFalloff * scatter * lightColor * lightAttenuation;
    
    return transmission;
}

// 简化版透射计算 (不需要阴影深度，基于法线和光照方向)
float3 CalculateTransmissionSimple(
    uint profileId,
    float3 worldNormal,
    float3 lightDir,
    float3 viewDir,
    float3 lightColor,
    float lightAttenuation,
    float thickness)  // 可以从材质或 GBuffer 传入
{
    TransmissionParams params = GetTransmissionParams(profileId);
    
    // 缩放厚度
    float scaledThickness = thickness * params. extinctionScale;
    
    // 从 Transmission Profile 采样
    float4 transmissionProfile = SampleTransmissionProfile(profileId, scaledThickness);
    float3 transmissionColor = transmissionProfile. rgb;
    float shadowFalloff = transmissionProfile.a;
    
    // 背面光照
    float NdotL = dot(worldNormal, lightDir);
    float backLighting = saturate(-NdotL);
    
    // View-dependent 散射
    float VdotL = saturate(dot(-viewDir, lightDir));
    float scatter = lerp(backLighting, pow(VdotL, 4.0), params.scatteringDistribution * 0.5 + 0.5);
    
    // 法线影响
    scatter *= (1.0 + params.normalScale * (1.0 - backLighting));
    
    // 最终透射
    float3 transmission = transmissionColor * shadowFalloff * scatter * lightColor * lightAttenuation;
    
    return transmission;
}

#endif // SSPROFILE_COMMON_INCLUDED