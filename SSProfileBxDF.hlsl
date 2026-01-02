#ifndef SOUL_SSPROFILE_BXDF_INCLUDE
#define SOUL_SSPROFILE_BXDF_INCLUDE

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/BRDF.hlsl"
#include "SSProfileSampling.hlsl"
#include "BurleyNormalizedSSS.hlsl"

struct SSProfileLightingContext
{
    float3 N;       
    float3 V;       
    float3 L;       
    float  NoV;
    float  NoL;
    float  NoH;
    float  VoH;
    float  LoV;   
};

SSProfileLightingContext CreateLightingContext(float3 N, float3 V, float3 L)
{
    SSProfileLightingContext ctx;
    ctx.N = N;
    ctx.V = V;
    ctx.L = L;
    
    float3 H = normalize(V + L);
    ctx.NoV = saturate(dot(N, V) + 1e-5);
    ctx.NoL = saturate(dot(N, L));
    ctx.NoH = saturate(dot(N, H));
    ctx.VoH = saturate(dot(V, H));
    ctx.LoV = dot(L, V);
    
    return ctx;
}


// ============================================================================
// 能量守恒相关函数
// ============================================================================

// 计算平均 Fresnel（用于能量补偿）
float3 EnvBRDFApprox(float3 specularColor, float roughness, float NoV)
{
    // Lazarov 2013, "Getting More Physical in Call of Duty: Black Ops II"
    const float4 c0 = float4(-1, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1, 0.0425, 1.04, -0.04);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
    float2 AB = float2(-1.04, 1.04) * a004 + r.zw;
    return specularColor * AB.x + AB.y;
}

// Diffuse 能量补偿（考虑 Specular 消耗的能量）
float3 ComputeDiffuseEnergyConservation(float3 diffuseColor, float3 specularEnergy)
{
    // diffuseColor * (1 - Fspec_avg)
    return diffuseColor * (1.0 - specularEnergy);
}

// 多次散射补偿（UE5 使用的简化模型）
float3 ComputeMultipleScattering(float3 specularColor, float roughness, float NoV)
{
    // Fdez-Agüera 2019, "A Multiple-Scattering Microfacet Model for Real-Time Image-based Lighting"
    float3 FssEss = EnvBRDFApprox(specularColor, roughness, NoV);
    
    // Ems = (1 - Ess) / (1 - Eavg)
    float Eavg = EnvBRDFApprox(specularColor, roughness, 0.5).x;
    float3 Fms = FssEss * Eavg / (1.0 - specularColor * (1.0 - Eavg));
    
    return Fms;
}

// ============================================================================
// Dual Specular BRDF（能量守恒版本）
// ============================================================================

float D_GGX_UE5(float roughness, float NoH)
{
    float a = roughness * roughness;
    float a2 = a * a;
    float d = (NoH * a2 - NoH) * NoH + 1.0;
    return a2 / (PI * d * d + 1e-7);
}

float Vis_SmithGGXCorrelated(float roughness, float NoV, float NoL)
{
    float a = roughness * roughness;
    float a2 = a * a;
    
    float GGXV = NoL * sqrt(NoV * NoV * (1.0 - a2) + a2);
    float GGXL = NoV * sqrt(NoL * NoL * (1.0 - a2) + a2);
    
    return 0.5 / (GGXV + GGXL + 1e-5);
}

float3 F_Schlick_UE5(float3 f0, float VoH)
{
    float Fc = pow(1.0 - VoH, 5.0);
    return saturate(50.0 * f0.g) * Fc + (1.0 - Fc) * f0;
}

// Dual Specular（两层 GGX Lobe + 能量守恒）
float3 DualSpecularGGX(
    float roughness0, 
    float roughness1, 
    float lobeMix, 
    float3 specularColor, 
    float NoV, 
    float NoL, 
    float NoH, 
    float VoH,
    out float3 energyCompensation)  
{
    // Lobe 0
    float D0 = D_GGX_UE5(roughness0, NoH);
    float Vis0 = Vis_SmithGGXCorrelated(roughness0, NoV, NoL);
    float3 F0 = F_Schlick_UE5(specularColor, VoH);
    float3 spec0 = D0 * Vis0 * F0;
    
    // Lobe 1
    float D1 = D_GGX_UE5(roughness1, NoH);
    float Vis1 = Vis_SmithGGXCorrelated(roughness1, NoV, NoL);
    float3 F1 = F_Schlick_UE5(specularColor, VoH);
    float3 spec1 = D1 * Vis1 * F1;
    
    // 混合
    float3 specular = lerp(spec0, spec1, lobeMix);
    
    //能量补偿：计算平均粗糙度的多次散射项
    float avgRoughness = lerp(roughness0, roughness1, lobeMix);
    energyCompensation = ComputeMultipleScattering(specularColor, avgRoughness, NoV);
    
    return specular;
}

// ============================================================================
// Burley Diffuse（能量守恒版本）
// ============================================================================

float3 Diffuse_Burley_EnergyConserving(
    float3 diffuseColor, 
    float roughness, 
    float NoV, 
    float NoL, 
    float VoH,
    float3 specularEnergy) 
{
    // 原始 Burley
    float FD90 = 0.5 + 2.0 * VoH * VoH * roughness;
    float FdV = 1.0 + (FD90 - 1.0) * pow(1.0 - NoV, 5.0);
    float FdL = 1.0 + (FD90 - 1.0) * pow(1.0 - NoL, 5.0);
    float burley = INV_PI * FdV * FdL;
    
    //能量守恒：扣除 Specular 占用的能量
    float3 energyConservedDiffuse = ComputeDiffuseEnergyConservation(diffuseColor, specularEnergy);
    
    return energyConservedDiffuse * burley;
}

// ============================================================================
// Transmission 计算（Burley 模型）
// ============================================================================

// 厚度采样接口
float SampleThickness(float2 uv)
{
    //方案 1: 从厚度贴图采样
    #ifdef _THICKNESS_MAP
        return SAMPLE_TEXTURE2D(_ThicknessMap, sampler_ThicknessMap, uv).r;
    #else
        // 默认厚度（单位：cm）
        return 0.5;
    #endif
}

//预留接口：实时厚度计算（后续实现）
float ComputeRealtimeThickness(float3 positionWS, float3 normalWS, float3 lightDirWS)
{
    // TODO: Screen-space thickness 或 Shadow map-based thickness
    return 0.5; // 占位值
}

// Burley Transmission（背光透射）
float3 ComputeBurleyTransmission(
    SSProfileParams profile,
    float3 viewDirWS,
    float3 lightDirWS,
    float3 normalWS,
    float thickness,
    float3 lightColor)
{
    float3 scatterDir = -lightDirWS + normalWS * profile.normalScale;
    float VoL = saturate(dot(viewDirWS, -scatterDir));
    
    float g = profile.scatteringDistribution;
    float phase = (1.0 - g * g) / (4.0 * PI * pow(1.0 + g * g - 2.0 * g * VoL, 1.5) + 1e-5);
    
    float3 scalingFactor = GetSearchLightDiffuseScalingFactor3D(profile.surfaceAlbedo);
    
    float thicknessInMm = thickness * profile.worldUnitScale * 10.0; // cm -> mm
    
    float3 transmission = BurleyTransmission3D(
        thicknessInMm,
        profile.surfaceAlbedo,
        scalingFactor,
        profile.diffuseMeanFreePath
    );
    
    transmission *= profile.boundaryColorBleed;
    
    return transmission * phase * lightColor;
}

#endif