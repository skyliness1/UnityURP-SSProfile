#ifndef SOUL_SSPROFILE_LIGHTING_INCLUDE
#define SOUL_SSPROFILE_LIGHTING_INCLUDE

#include "SSProfileBxDF.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SoulGBuffer.hlsl"

struct SSProfileLightingResult
{
    float3 diffuse;
    float3 specular;
    float3 transmission;
};

SSProfileLightingResult SSProfileDirectLighting(
    SSProfileParams profile,
    SSProfileLightingContext ctx,
    float3 baseColor,
    float  metallic,
    float3 lightColor,
    float  lightAttenuation,
    float  thickness,           
    bool   enableTransmission)  
{
    SSProfileLightingResult result;
    result.diffuse = 0;
    result.specular = 0;
    result.transmission = 0;
    
    // ========================================================================
    // 1. 计算基础材质参数
    // ========================================================================
    
    float3 diffuseColor = baseColor * (1.0 - metallic);
    float3 specularColor = lerp(0.04, baseColor, metallic);
    
    float3 energyCompensation;
    float3 directSpecular = DualSpecularGGX(
        profile.roughness0,
        profile.roughness1,
        profile.lobeMix,
        specularColor,
        ctx.NoV,
        ctx.NoL,
        ctx.NoH,
        ctx.VoH,
        energyCompensation
    );
    
    //添加多次散射补偿
    result.specular = directSpecular + energyCompensation * (1.0 - directSpecular);
    
    // ========================================================================
    // 3. Diffuse - Burley（能量守恒）
    // ========================================================================
    
    // 计算 Specular 的平均能量占用
    float3 specularEnergy = EnvBRDFApprox(specularColor, profile.avgRoughness, ctx.NoV);
    
    result.diffuse = Diffuse_Burley_EnergyConserving(
        diffuseColor,
        profile.avgRoughness,
        ctx.NoV,
        ctx.NoL,
        ctx.VoH,
        specularEnergy
    );
    
    // ========================================================================
    // 4. Transmission（背光透射）
    // ========================================================================
    
    if (enableTransmission)
    {
        result.transmission = ComputeBurleyTransmission(
            profile,
            ctx.V,
            ctx.L,
            ctx.N,
            thickness,
            lightColor * lightAttenuation
        );
    }
    
    return result;
}

// ============================================================================
// 简化接口
// ============================================================================

float3 SSProfileLighting_Complete(
    uint   profileID,
    float3 baseColor,
    float  metallic,
    float3 normalWS,
    float3 viewDirWS,
    float3 lightDirWS,
    float3 lightColor,
    float  lightAttenuation,
    float  thickness,
    bool   enableTransmission)
{
  
    SSProfileParams profile = LoadSSProfileParams(profileID);
    
    SSProfileLightingContext ctx = CreateLightingContext(normalWS, viewDirWS, lightDirWS);
    
    SSProfileLightingResult lighting = SSProfileDirectLighting(
        profile, 
        ctx, 
        baseColor, 
        metallic, 
        lightColor, 
        lightAttenuation,
        thickness,
        enableTransmission
    );
    
    float3 surfaceLighting = (lighting.diffuse + lighting.specular) * ctx.NoL * lightColor * lightAttenuation;
    
    return surfaceLighting + lighting.transmission;
}

#endif