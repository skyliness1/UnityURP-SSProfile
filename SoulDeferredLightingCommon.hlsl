#ifndef SOUL_DEFERRED_LIGHTING_COMMON_INCLUDE
#define SOUL_DEFERRED_LIGHTING_COMMON_INCLUDE

#define SOUL_DEFERRED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceData.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/LightLoop/SoulLightLoop.hlsl"

//#include "Packages/com.unity.render-pipelines.universal/Shaders/Soul/RayTracing/RayTracingCommon.hlsl"

//Scene Params Set By Global
half _SsrRelectionIntensity;

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
};

BRDFData GBufferToBRDF(GBufferData GBuffer)
{
    BRDFData brdfData = (BRDFData)0;
    half alpha = half(1.0); // NOTE: alpha can get modfied, forward writes it out (_ALPHAPREMULTIPLY_ON).
    InitializeBRDFData(GBuffer.baseColor, GBuffer.metallic, 0, GBuffer.smoothness, alpha, brdfData, 1);

    //PC FO 矫正
    brdfData.specular = lerp(_NoMetalF0, GBuffer.baseColor, GBuffer.metallic);
    
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

//**********************************  SSProfile Lighting *********************************************************//
#include "Packages/com.unity.render-pipelines.universal@14.0.11/ArtShaders/Scene/SSProfile/Shaders/Include/SSProfileLighting.hlsl"
//**********************************  SSProfile Lighting *********************************************************//
float3 AccumulateLightingSSProifle(GBufferData GBuffer, Light mainLight, float3 viewDirectionWS, float directAO)
{
    uint profileID = ExtractProfileID(GBuffer.customDataSingle);
    SSProfileParams profile = LoadSSProfileParams(profileID);
    SSProfileLightingContext context = CreateLightingContext(GBuffer.normalWS, viewDirectionWS, mainLight.direction);
    float lightAtten = mainLight.shadowAttenuation * mainLight.distanceAttenuation;
    SSProfileLightingResult lightResult = SSProfileDirectLighting(profile, context, GBuffer.baseColor,
        GBuffer.metallic, mainLight.color, lightAtten, 0.5, true);
    float3 surfaceLighting = (lightResult.diffuse + lightResult.specular) * context.NoL * mainLight.color * lightAtten;
    surfaceLighting *= min(GBuffer.ao, directAO); 
    float3 totalLight = surfaceLighting + lightResult.transmission;
    return totalLight;
}

float3 AccumulateAdditionalLightingSSProfile(
    PositionInputs posInput, 
    GBufferData GBuffer, 
    float3 viewDirectionWS, 
    uint lightLayer,
    float directAO)
{
    float3 totalLight = 0;
    
    uint pixelLightCount = GetAdditionalLightsCount();
    for (uint lightIndex = 0u; lightIndex < pixelLightCount; ++lightIndex)
    {
        Light light = GetAdditionalLight(lightIndex, posInput.positionWS);
        
        if (IsMatchingLightLayer(light.layerMask, lightLayer))
        {
            totalLight += AccumulateLightingSSProifle(GBuffer, light, viewDirectionWS, directAO);
        }
    }
    
    return totalLight;
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
        const int kernelSize = 3;
        //const int rtgbGlobalIndex = GetNextCompositFrame(_CurCompositeFrame);
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
                    uv, 0).xyz * ratio;
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
    if(GBuffer.shadingModelID == SHADINGMODELID_DEFAULT_LIT_SCENE || GBuffer.shadingModelID == SHADINGMODELID_SUBSURFACE_PROFILE)
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
    if(GBuffer.shadingModelID == SHADINGMODELID_SUBSURFACE_PROFILE)
    {
        float2 normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(posInput.positionSS);
        AmbientOcclusionFactor aoFactor = GetScreenSpaceAmbientOcclusion(normalizedScreenSpaceUV);
        lightAccumulator.totalLight += GBuffer.staticLighting * min(aoFactor.indirectAmbientOcclusion, GBuffer.ao);
        lightAccumulator.totalLight += AccumulateLightingSSProifle(GBuffer, mainLight, viewDirectionWS, aoFactor.directAmbientOcclusion);
        #ifdef SOUL_CLUSTERED_LIGHTING
        lightAccumulator.totalLight += AccumulateAdditionalLightingSSProfile(posInput, GBuffer, viewDirectionWS, GBuffer.lightLayer, aoFactor.directAmbientOcclusion);
        #endif
        
        //SSR
        //lightAccumulator.totalLight += EvaluateScreenSpaceReflection(posInput, brdfData, GBuffer, viewDirectionWS);
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
