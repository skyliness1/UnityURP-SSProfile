#ifndef SOUL_DEFERRED_LIGHTING_COMMON_INCLUDE
#define SOUL_DEFERRED_LIGHTING_COMMON_INCLUDE

#define SOUL_DEFERRED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceData.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/LightLoop/SoulLightLoop.hlsl"

//Scene Params Set By Global
half _SsrRelectionIntensity;

// SSProfile 支持
#include "Packages/com.unity.render-pipelines.universal/ArtShaders/Scene/SSProfile/Shaders/Include/SSProfileCommon.hlsl"

//PC FO 矫正
float _NoMetalF0;

//Character Parms Set By Global
#define INVPI  0.31831
float Cha_MainlightColor_Intensity;
float Cha_Mainlight_Intensity;
float4 Cha_Mainlight_TintColor;
float Cha_ShadowIntensity;

//点光标签
float _SceneSpotLightId;
struct LightAccumulator
{
    float3 totalLight;
    float3 diffuseLight;   // 新增: 分离的 Diffuse
    float3 specularLight;  // 新增: 分离的 Specular
};

bool IsCheckerboardEven(int2 pixelCoord)
{
    return ((pixelCoord.x + pixelCoord.y) & 1) == 0;
}

LightAccumulator GetDefaultLightAccumulator()
{
    LightAccumulator acc;
    acc.totalLight = float3(0, 0, 0);
    acc.diffuseLight = float3(0, 0, 0);
    acc.specularLight = float3(0, 0, 0);
    return acc;
}

BRDFData GBufferToBRDF(GBufferData GBuffer)
{
    BRDFData brdfData = (BRDFData)0;
    half alpha = half(1.0); // NOTE: alpha can get modfied, forward writes it out (_ALPHAPREMULTIPLY_ON).
    InitializeBRDFData(GBuffer.baseColor, GBuffer.metallic, 0, GBuffer.smoothness, alpha, brdfData, 1);

    //PC FO 矫正
    brdfData.specular = lerp(_NoMetalF0, GBuffer.baseColor, GBuffer.metallic);
    
    return brdfData;
}

// SSS 专用 BRDF (metallic 通道被复用为 opacity)
BRDFData GBufferToBRDF_SSS(GBufferData GBuffer)
{
    BRDFData brdfData = (BRDFData)0;
    half alpha = half(1.0);
    InitializeBRDFData(GBuffer.baseColor, 0, 0, GBuffer.smoothness, alpha, brdfData, 1);
    brdfData.specular = _NoMetalF0; // 非金属 F0
    return brdfData;
}

BRDFData GBufferToBRDF_Weapon(GBufferData GBuffer,float nol)
{
    BRDFData brdfData = (BRDFData)0;
    half oneMinusReflectivity = OneMinusReflectivityMetallic(GBuffer.metallic);
    half reflectivity = 1.0 - oneMinusReflectivity;
    half3 brdfDiffuse = GBuffer.baseColor * lerp(1,oneMinusReflectivity,nol);
    half3 brdfSpecular = lerp(kDieletricSpec.rgb, GBuffer.baseColor, GBuffer.metallic);
    half alpha = 1.0;
    InitializeBRDFDataDirect(brdfDiffuse, brdfSpecular, reflectivity, oneMinusReflectivity, GBuffer.smoothness, alpha, brdfData);
    return brdfData;
}


// ============================================================================
// Dual Specular 计算 (UE5 风格)
// ============================================================================
float3 CalculateDualSpecular(
    BRDFData brdfData,
    float3 normalWS,
    float3 lightDir,
    float3 viewDir,
    float roughness0,
    float roughness1,
    float lobeMix)
{
    // Lobe 0
    BRDFData brdfData0 = brdfData;
    brdfData0.roughness = saturate(roughness0 * brdfData.roughness);
    brdfData0.roughness2 = brdfData0.roughness * brdfData0.roughness;
    brdfData0.normalizationTerm = brdfData0.roughness * 4.0 + 2.0;
    brdfData0.roughness2MinusOne = brdfData0.roughness2 - 1.0;
    
    // Lobe 1
    BRDFData brdfData1 = brdfData;
    brdfData1.roughness = saturate(roughness1 * brdfData.roughness);
    brdfData1.roughness2 = brdfData1.roughness * brdfData1.roughness;
    brdfData1.normalizationTerm = brdfData1.roughness * 4.0 + 2.0;
    brdfData1.roughness2MinusOne = brdfData1.roughness2 - 1.0;
    
    float3 spec0 = DirectBRDFSpecular(brdfData0, normalWS, lightDir, viewDir);
    float3 spec1 = DirectBRDFSpecular(brdfData1, normalWS, lightDir, viewDir);
    
    return lerp(spec0, spec1, lobeMix);
}

// ============================================================================
// SSS Profile 光照计算 (分离 Diffuse 和 Specular)
// ============================================================================
void AccumulateLightingSSS(
    BRDFData brdfData,
    GBufferData GBuffer,
    Light light,
    float3 viewDirectionWS,
    uint profileId,
    inout float3 diffuseAccum,
    inout float3 specularAccum)
{
    half NdotL = saturate(dot(GBuffer.normalWS, light.direction));
    half lightAtten = light.distanceAttenuation * light.shadowAttenuation;
    half3 radiance = light.color * lightAtten * NdotL;
    
    // Diffuse
    diffuseAccum += brdfData.diffuse * radiance;
    
    // Dual Specular
    float roughness0, roughness1, lobeMix;
    GetSubsurfaceProfileDualSpecular(profileId, roughness0, roughness1, lobeMix);
    
    float3 spec = CalculateDualSpecular(brdfData, GBuffer.normalWS, light.direction,
                                        viewDirectionWS, roughness0, roughness1, lobeMix);
    specularAccum += spec * brdfData.specular * radiance;
}

// ============================================================================
// 附加光源 SSS 计算
// ============================================================================
#ifdef SOUL_CLUSTERED_LIGHTING
void AccumulateAdditionalLightingSSS(
    PositionInputs posInput,
    BRDFData brdfData,
    GBufferData GBuffer,
    float3 viewDirectionWS,
    uint profileId,
    inout float3 diffuseAccum,
    inout float3 specularAccum)
{
    uint lightCount = GetAdditionalLightsCount();
    
    for (uint i = 0; i < lightCount; i++)
    {
        Light light = GetAdditionalLight(i, posInput.positionWS, GBuffer.shadowMask);
        
        if (! IsMatchingLightLayer(light.layerMask, GBuffer.lightLayer))
            continue;
        
        AccumulateLightingSSS(brdfData, GBuffer, light, viewDirectionWS, profileId,
                              diffuseAccum, specularAccum);
    }
}
#endif


//**********************************  Scene Lighting *********************************************************//
float3 AccumulateLightingScene(BRDFData brdfData, GBufferData GBuffer, Light mainLight, float3 viewDirectionWS)
{
    BRDFData noClearCoat = (BRDFData)0;
    bool specularHighlightsOff = false;
    half directSpecMask = 0;
    half noClearCotaMast = 0;
    //直接光AO增强
    mainLight.color *= GBuffer.ao;
    
    half nDotL = saturate(dot(mainLight.direction, GBuffer.normalWS));
    float3 totalLight = LightingPhysicallyBasedSceneUE4(brdfData, nDotL, mainLight,GBuffer.normalWS, viewDirectionWS,noClearCotaMast, specularHighlightsOff,0, GBuffer.metallic,directSpecMask);
    
    //提高饱和度
    half3 saturationColor = SceneSaturation(totalLight);
    //烘焙对象考虑Shadowmask
    nDotL *= GBuffer.shadowMask;
    totalLight = lerp(totalLight, saturationColor, nDotL);
    
    return totalLight;
}

float3 AccumulateLightingScene(BRDFData brdfData, GBufferData GBuffer, Light mainLight, float3 viewDirectionWS, float directAmbientOcclusion)
{
    BRDFData noClearCoat = (BRDFData) 0;
    bool specularHighlightsOff = false;
    half directSpecMask = 0;
    half noClearCotaMast = 0;
    //直接光SSAO增强
    mainLight.color *= min(directAmbientOcclusion, GBuffer.ao);
    
    half nDotL = saturate(dot(mainLight.direction, GBuffer.normalWS));
    float3 totalLight = LightingPhysicallyBasedSceneUE4(brdfData, nDotL, mainLight, GBuffer.normalWS, viewDirectionWS, noClearCotaMast, specularHighlightsOff, 0, GBuffer.metallic, directSpecMask);
    
    //提高饱和度
    half3 saturationColor = SceneSaturation(totalLight);
    //烘焙对象考虑Shadowmask
    nDotL *= GBuffer.shadowMask;
    totalLight = lerp(totalLight, saturationColor, nDotL);
    
    return totalLight;
}
//**********************************  Scene Lighting *********************************************************//

//**********************************  Vegetation Lighting *********************************************************//
float3 AccumulateLightingVeg(BRDFData brdfData, GBufferData GBuffer, Light mainLight, float3 viewDirectionWS, half3 subsurfaceColor)
{
    half sNoL = dot(GBuffer.normalWS, mainLight.direction);
    half NoL = saturate(sNoL);

    half shadow = mainLight.distanceAttenuation * mainLight.shadowAttenuation;
  
    half lightAtten = NoL * shadow;
    // half rampX = (sNoL * 0.5f + 0.5f) * shadow;
    // half3 rampTex = _RampTex.Sample(sampler_RampTex, float2(rampX, 0.5f)).rgb;
    // brdfData.diffuse *= lerp(lightAtten, rampTex * _RampTexMultiplier, _UseRampTex);

    half VoL = max(0.0f, dot(-viewDirectionWS, mainLight.direction));
    half VoL5 = Pow4(VoL) * VoL;
    // 实际上乘了两次li.NoL * li.shadow
    half subsurfaceAtten = VoL5 * lightAtten;
    
    half3 diffuse = brdfData.diffuse;
    half3 subsurface = subsurfaceColor * subsurfaceAtten;
    half3 lighting = mainLight.color;

    //不知道为什么之前diffuse * shadow ,找时间问旭哥,是不是搞错了
    float3 totalLight = (diffuse + subsurface * lightAtten) * lighting;

    return totalLight;
}
//**********************************  Vegetation Lighting *********************************************************//

//**********************************  Character Lighting *********************************************************//
#include "Packages/com.unity.render-pipelines.universal/Shaders/Soul/Character/CharacterV1/CHRMain_DeferredLighting.hlsl"
//**********************************  Weapon Lighting *********************************************************//
float3 AccumulateLightingWeapon(GBufferData GBuffer,Light mainLight,float3 viewDirectionWS)
{
    half NdotL = saturate(dot (GBuffer.normalWS, mainLight.direction));
    BRDFData brdfData = GBufferToBRDF_Weapon(GBuffer,NdotL);
    
    half lightAttenuation = mainLight.distanceAttenuation * mainLight.shadowAttenuation;
    half _ShadowBoost = GBuffer.ao;
    NdotL = clamp( NdotL, clamp( _ShadowBoost, 0, 1), 1);//暗部提亮
    half3 radiance = mainLight.color * (lightAttenuation * NdotL);

    half3 brdf = brdfData.diffuse;
    brdf += brdfData.specular * DirectBRDFSpecular(brdfData, GBuffer.normalWS, mainLight.direction, viewDirectionWS);

    return brdf * radiance;
}

TEXTURE2D_X(_SsrReflectionTexture);
float _ColorPyramidMipCount;
float _SampleLODInDeferredPass;
float _RtrStrength;
TEXTURE2D_X(_GBufferNormal);
TEXTURE2D_X(_GBufferShadingModelID);
SamplerState my_Trilinear_clamp_sampler;
float3 EvaluateScreenSpaceReflection(PositionInputs posInput, BRDFData brdfData, GBufferData GBuffer, float3 viewDirectionWS)
{
#if _SCREEN_SPACE_REFLECTION
    float NoV = saturate(dot(GBuffer.normalWS, viewDirectionWS));
    float fresnelTerm = Pow4(1.0 - NoV);
    float3 sampleRes = float3(0,0,0);
    if(_SampleLODInDeferredPass < 0.5)
    {
        sampleRes = SAMPLE_TEXTURE2D_X(_SsrReflectionTexture, sampler_LinearClamp, posInput.positionNDC).xyz;
    }
    else
    {
        float mipLevel = lerp(0, _ColorPyramidMipCount - 1, brdfData.perceptualRoughness) * 0.5f;
        float totalCount = 0;
        const int kernelSize = 5;
        for(int i = 0; i < kernelSize; ++i)
        {
            for(int j = 0; j < kernelSize; ++j)
            {
                float3 judgeNormal = GBuffer.normalWS;
                uint judgeShadingModelID = GBuffer.shadingModelID;
                float2 uv = posInput.positionNDC + float2(i - kernelSize/2, j - kernelSize/2) * _ScreenSize.zw;
                if(i != kernelSize/2 || j != kernelSize/2)
                {
                    int2 ss = posInput.positionSS + float2(i - kernelSize/2, j - kernelSize/2);
                    GBufferTypeC inGBufferC = LOAD_TEXTURE2D_X(_GBufferNormal, ss);
                    GBufferTypeD inGBufferD = LOAD_TEXTURE2D_X(_GBufferShadingModelID, ss);
                    GBufferData GBufferN;
                    DECODE_FROM_GBUFFER(0,0,inGBufferC,inGBufferD,0,GBufferN);
                    judgeNormal = GBufferN.normalWS;
                    judgeShadingModelID = GBufferN.shadingModelID;
                }
                float ratio = judgeShadingModelID == GBuffer.shadingModelID ? pow(max(dot(judgeNormal, GBuffer.normalWS),0.0f),3) : 0.0f;
                sampleRes += SAMPLE_TEXTURE2D_X_LOD(
                    _SsrReflectionTexture, my_Trilinear_clamp_sampler, 
                    uv, mipLevel).xyz * ratio;
                totalCount += ratio + 0.01f;
            }
        }
        sampleRes /= totalCount;
        return pow(sampleRes, 0.45) * _RtrStrength;//SAMPLE_TEXTURE2D_X(_SsrReflectionTexture, sampler_LinearClamp, posInput.positionNDC).xyz;
    }
    return sampleRes * EnvironmentBRDFSpecular(brdfData, fresnelTerm);
#else
    return 0.0;
#endif
}

LightAccumulator AccumulateLighting(GBufferData GBuffer, PositionInputs posInput, float3 viewDirectionWS)
{
    LightAccumulator lightAccumulator = (LightAccumulator)0;
    
    UNITY_BRANCH
    if(GBuffer.shadingModelID==SHADINGMODELID_UNLIT)
    {
        lightAccumulator.totalLight += GBuffer.staticLighting;
        return lightAccumulator;
    }

    //因为现在 subsurface 用的很trick ,拿三个通道拼出来的，但又不能影响brdf的计算,所以只能trick上面加trick
    float3 subsurfaceColor = 0;
    UNITY_BRANCH
    if(GBuffer.shadingModelID == SHADINGMODELID_DEFAULT_LIT_VEGETATION || GBuffer.shadingModelID == SHADINGMODELID_DEFAULT_LIT_GRASS)
    {
        subsurfaceColor = float3(GBuffer.ao, GBuffer.metallic, GBuffer.customDataSingle);
        GBuffer.metallic = 0;
    }

    UNITY_BRANCH
    if (GBuffer.shadingModelID == SHADINGMODELID_SUBSURFACE_PROFILE)
    {
        // 提取 SSS 数据
        uint profileId = (uint)(GBuffer.customDataSingle * 255.0 + 0.5);
        float opacity = GBuffer. metallic;
        
        // 使用 SSS 专用 BRDF
        BRDFData brdfData = GBufferToBRDF_SSS(GBuffer);
        
        // 获取主光源
        float4 shadowCoord = TransformWorldToShadowCoord(posInput.positionWS);
        Light mainLight = GetMainLight(shadowCoord, posInput.positionWS, GBuffer. shadowMask);
        
        #if defined(CONTACT_SHADOWS)
        mainLight.shadowAttenuation = min(GetLightContactShadow(posInput. positionSS, GBuffer. normalWS, mainLight.direction, 1), mainLight.shadowAttenuation);
        #endif
        
        half isMainLightCulling = IsMatchingLightLayer(mainLight.layerMask, GBuffer.lightLayer) ? 1.0 : 0.0;
        mainLight. distanceAttenuation = isMainLightCulling;
        
        // 计算 Diffuse 和 Specular
        float3 diffuse = float3(0, 0, 0);
        float3 specular = float3(0, 0, 0);
        
        AccumulateLightingSSS(brdfData, GBuffer, mainLight, viewDirectionWS, profileId, diffuse, specular);
        
        // 附加光源
        #ifdef SOUL_CLUSTERED_LIGHTING
        AccumulateAdditionalLightingSSS(posInput, brdfData, GBuffer, viewDirectionWS, profileId, diffuse, specular);
        #endif
        
        // SSAO
        float2 normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(posInput.positionSS);
        AmbientOcclusionFactor aoFactor = GetScreenSpaceAmbientOcclusion(normalizedScreenSpaceUV);
        
        // GI 加到 Diffuse
        diffuse += GBuffer.staticLighting * min(aoFactor.indirectAmbientOcclusion, GBuffer.ao);
        
        // 应用 Opacity
        diffuse *= opacity;
        
        // SSR 加到 Specular
        specular += EvaluateScreenSpaceReflection(posInput, brdfData, GBuffer, viewDirectionWS);
        
        // ================================================================
        // 棋盘格编码输出
        // 偶数像素 (x+y 为偶数): 输出 Diffuse
        // 奇数像素 (x+y 为奇数): 输出 Specular
        // ================================================================
        bool isEvenPixel = IsCheckerboardEven(int2(posInput.positionSS));
        lightAccumulator.totalLight = isEvenPixel ? diffuse :  specular;
        lightAccumulator.diffuseLight = diffuse;
        lightAccumulator.specularLight = specular;
        
        return lightAccumulator;
    }
    
    BRDFData brdfData = GBufferToBRDF(GBuffer);
    float4 shadowCoord = TransformWorldToShadowCoord(posInput.positionWS);
    half shadowMask = GBuffer.shadowMask;

    half customShadowIntensity = 1;
    if(GBuffer.shadingModelID == SHADINGMODELID_DEFAULT_LIT_VEGETATION || GBuffer.shadingModelID == SHADINGMODELID_DEFAULT_LIT_GRASS)
    {
        customShadowIntensity = _VegetationDeferredLightingShadowIntensity;
    }
    
    Light mainLight = GetMainLightWithCustomRealTimeShadowIntensity(shadowCoord, posInput.positionWS, shadowMask, customShadowIntensity);

    #if defined(CONTACT_SHADOWS)
    mainLight.shadowAttenuation = min(GetLightContactShadow(posInput.positionSS, GBuffer.normalWS, mainLight.direction, 1), mainLight.shadowAttenuation);;
    #endif
    
    half isMainLightCulling = IsMatchingLightLayer(mainLight.layerMask, GBuffer.lightLayer) ? 1.0 : 0.0;
    // unity_LightData.z is set per mesh for forward renderer, we cannot cull lights in this fashion with deferred renderer.
    mainLight.distanceAttenuation = isMainLightCulling;

    //trick2
    //因为这个野外的烘焙的shadowmask是截断自定义, 但是室内还是非黑即白的, 所以这里也要跟着那波逻辑做一个判断
    half isOutdoor = 0;
    if(GBuffer.shadingModelID == SHADINGMODELID_DEFAULT_LIT_SCENE)
    {
        float trick = step(0.05 , GBuffer.shadowMask.x);
        isOutdoor = trick;
        half shadowThreshold = lerp(0.1, _SoulCustomShadowThreshold, _SoulCustomLightEnable);
        half outdoorRealtimeShadow = max(mainLight.shadowAttenuation, shadowThreshold);
        mainLight.shadowAttenuation = lerp( mainLight.shadowAttenuation, outdoorRealtimeShadow, isOutdoor);
    }


    UNITY_BRANCH
    if (GBuffer.shadingModelID == SHADINGMODELID_DEFAULT_LIT_SCENE)
    {
        //SSAO....................
        float2 normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(posInput.positionSS);
        AmbientOcclusionFactor aoFactor = GetScreenSpaceAmbientOcclusion(normalizedScreenSpaceUV);
        lightAccumulator.totalLight += GBuffer.staticLighting * min(aoFactor.indirectAmbientOcclusion, GBuffer.ao);
        
        lightAccumulator.totalLight += AccumulateLightingScene(brdfData, GBuffer, mainLight, viewDirectionWS, aoFactor.directAmbientOcclusion);
        #ifdef SOUL_CLUSTERED_LIGHTING
        lightAccumulator.totalLight += AccumulateAdditionalLighting(posInput, brdfData, GBuffer.normalWS, viewDirectionWS, GBuffer.lightLayer);
        #endif
        //lightAccumulator.totalLight *= 0.f;
        //SSR
        lightAccumulator.totalLight += EvaluateScreenSpaceReflection(posInput, brdfData, GBuffer, viewDirectionWS);
    }
    
    UNITY_BRANCH
    if(GBuffer.shadingModelID == SHADINGMODELID_DEFAULT_LIT_UISCENE)
    {
       mainLight.shadowAttenuation = 1;
       //SSAO....................
       float2 normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(posInput.positionSS);
       AmbientOcclusionFactor aoFactor = GetScreenSpaceAmbientOcclusion(normalizedScreenSpaceUV);
       lightAccumulator.totalLight += GBuffer.staticLighting * min(aoFactor.indirectAmbientOcclusion, GBuffer.ao);
        
       lightAccumulator.totalLight += AccumulateLightingScene(brdfData, GBuffer, mainLight, viewDirectionWS, aoFactor.directAmbientOcclusion) * GBuffer.shadowMask;
       #ifdef SOUL_CLUSTERED_LIGHTING
       lightAccumulator.totalLight += AccumulateAdditionalLighting(posInput, brdfData, GBuffer.normalWS, viewDirectionWS, GBuffer.lightLayer);
       #endif
    }

    UNITY_BRANCH
    if(GBuffer.shadingModelID == SHADINGMODELID_DEFAULT_LIT_VEGETATION || GBuffer.shadingModelID == SHADINGMODELID_DEFAULT_LIT_GRASS)
    {
        //SSAO....................
        float2 normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(posInput.positionSS);
        AmbientOcclusionFactor aoFactor = GetScreenSpaceAmbientOcclusion(normalizedScreenSpaceUV);                                                                                                                                                                                                                                                                                                                                                                                                                                          
        lightAccumulator.totalLight += GBuffer.staticLighting * aoFactor.indirectAmbientOcclusion;
        lightAccumulator.totalLight += AccumulateLightingVeg(brdfData, GBuffer, mainLight, viewDirectionWS, subsurfaceColor) * aoFactor.directAmbientOcclusion;
    }
   
    return lightAccumulator;
}

#endif //SOUL_DEFERRED_LIGHTING_COMMON_INCLUDE
