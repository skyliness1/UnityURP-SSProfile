#ifndef SOUL_GBUFFERUTIL_INCLUDED
#define SOUL_GBUFFERUTIL_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceData.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/NormalBuffer.hlsl"

//*------------------------------------------------------*//
//GBufferA:GI+Emissive+OutLine
//GBufferB: RGB:BaseColor.rgb,A:ShadowMask/CustomData
//GBufferC:RGB:Normal.xy,A:AO/CustomData
//GBufferD:R:Metallic/CustomData,G:PerceptualRoughness,B:CustomDataSingle,A:ShadingModeID
//GBufferE:CustomData,CustomData,CustomData,CustomData
//*------------------------------------------------------*//

#define MAX_LIGHT_LAYERS 0xF

struct GBufferData
{
    half3 staticLighting;
    half shadowMask;
    half3 baseColor;
    half metallic;
    half3 normalWS; 
    half ao;
    half smoothness;
    half customDataSingle;
    uint shadingModelID;
    uint lightLayer;
    half4 customData;
    uint edgeMask;
    float dummy;
};


GBufferData GetDefaultGBufferData()
{
    GBufferData ret;
    ret.staticLighting = 0;
    ret.baseColor = 0; 
    ret.shadowMask = 0;
    ret.normalWS = 0;
    ret.ao = 0;
    ret.metallic = 0;
    ret.smoothness = 0;
    ret.customDataSingle = 0;
    ret.shadingModelID = 0;
    ret.lightLayer = 0;
    ret.customData = 0;
    return ret;
}

struct RayTracingReflectionGBufferPayload
{
    float3 viewOrigin;
    int insected;
    float3 worldPos;
    int generation;
    float3 accCenter;
    float blendAlpha;
    GBufferData gbufferData;
    float dummy;
};
RayTracingReflectionGBufferPayload GetInitializedGBufferPayload()
{
    RayTracingReflectionGBufferPayload payload;
    payload.gbufferData = GetDefaultGBufferData();
    payload.insected = 0;
    payload.generation = 0;
    payload.blendAlpha = 1.1;
    payload.viewOrigin = 0;
    payload.worldPos = 0;
    payload.accCenter = 0;
    
    return payload;
}

#define GBufferTypeA float3
#define GBufferTypeB float4
#define GBufferTypeC float4
#define GBufferTypeD float4
#define GBufferTypeE float4

//ShadingModeID
#define SHADINGMODELID_UNLIT		0
#define SHADINGMODELID_DEFAULT_LIT_SCENE  1
#define SHADINGMODELID_DEFAULT_LIT_VEGETATION  2
#define SHADINGMODELID_DEFAULT_LIT_UISCENE 3
#define SHADINGMODELID_DEFAULT_LIT_GRASS  4
#define SHADINGMODELID_SUBSURFACE_PROFILE 5

#ifdef NEED_GBUFFER_OPTIONAL
#define GBUFFERMATERIAL_CUSTOMDATA 1
#else
#define GBUFFERMATERIAL_CUSTOMDATA 0
#endif

#define GBUFFERMATERIAL_COUNT (4 + GBUFFERMATERIAL_CUSTOMDATA)


#if GBUFFERMATERIAL_COUNT == 4

#define OUTPUT_GBUFFER(NAME)                            \
out GBufferTypeA MERGE_NAME(NAME, A) : SV_Target0,    \
out GBufferTypeB MERGE_NAME(NAME, B) : SV_Target1,    \
out GBufferTypeC MERGE_NAME(NAME, C) : SV_Target2,    \
out GBufferTypeD MERGE_NAME(NAME, D) : SV_Target3


#define OUTPUT_GBUFFER_PARAMS(NAME) MERGE_NAME(NAME, A),MERGE_NAME(NAME, B),MERGE_NAME(NAME, C),MERGE_NAME(NAME, D)
#define OUTPUT_GBUFFER_VALUES(NAME) out GBufferTypeA MERGE_NAME(NAME, A),out GBufferTypeB MERGE_NAME(NAME, B),out GBufferTypeC MERGE_NAME(NAME, C),out GBufferTypeD MERGE_NAME(NAME, D)

#define ENCODE_INTO_GBUFFER(GBUFFER_DATA, NAME) EncodeIntoGBuffer(GBUFFER_DATA, MERGE_NAME(NAME, A), MERGE_NAME(NAME, B), MERGE_NAME(NAME, C), MERGE_NAME(NAME, D))

#elif GBUFFERMATERIAL_COUNT ==5

#define OUTPUT_GBUFFER(NAME)                            \
out GBufferTypeA MERGE_NAME(NAME, A) : SV_Target0,    \
out GBufferTypeB MERGE_NAME(NAME, B) : SV_Target1,    \
out GBufferTypeC MERGE_NAME(NAME, C) : SV_Target2,    \
out GBufferTypeD MERGE_NAME(NAME, D) : SV_Target3,     \
out GBufferTypeE MERGE_NAME(NAME, E) : SV_Target4

#define ENCODE_INTO_GBUFFER(GBUFFER_DATA, NAME) EncodeIntoGBuffer(GBUFFER_DATA, MERGE_NAME(NAME, A), MERGE_NAME(NAME, B), MERGE_NAME(NAME, C), MERGE_NAME(NAME, D), MERGE_NAME(NAME, E))
#endif

#define DECODE_FROM_GBUFFER(GBufferA, GBufferB, GBufferC, GBufferD, GBufferE, GBUFFER_DATA) DecodeFromGBuffer(GBufferA, GBufferB, GBufferC, GBufferD, GBufferE, GBUFFER_DATA)


float PackShadingModeAndLightLayer(uint shadeingMode,uint lightlayer,uint edgeMask)
{
    lightlayer &= MAX_LIGHT_LAYERS;
    uint maxInt =255;
    uint highBits = 0xE0&(shadeingMode<<5);
    uint lowBits = 0xF&lightlayer;
    uint edgeBit = edgeMask>0?0x10:0;
    uint res = (highBits|edgeBit|lowBits);
    return saturate(res * rcp(maxInt));
}

uint3 UnPackShadingModeAndLightLayer(float f)
{
    uint3 res;
    uint maxInt = 255;
    uint encodeVal = (uint)(f * maxInt + 0.5); // Round instead of truncating
    res.y = encodeVal&0xF;
    res.x = (encodeVal>>5)&0x7;
    res.z = encodeVal&0x10;
    return res;
}


void EncodeIntoGBuffer(GBufferData Gbuffer
                        ,out GBufferTypeA outGBufferA
                        ,out GBufferTypeB outGBufferB
                        ,out GBufferTypeC outGBufferC
                        ,out GBufferTypeD outGBufferD
 #if GBUFFERMATERIAL_COUNT > 4
                        , out GBufferTypeE outGBufferE
 #endif
                        )
{
    outGBufferA = Gbuffer.staticLighting;
    outGBufferB.rgb = Gbuffer.baseColor;
    outGBufferB.a = Gbuffer.shadowMask;

    NormalData normalData;
    normalData.normalWS = Gbuffer.normalWS;
    normalData.ao = Gbuffer.ao;
    EncodeIntoNormalBuffer(normalData,outGBufferC);
    
    outGBufferD.r = Gbuffer.metallic;
    outGBufferD.g = Gbuffer.smoothness;
    outGBufferD.b = Gbuffer.customDataSingle;
    outGBufferD.a = PackShadingModeAndLightLayer(Gbuffer.shadingModelID,Gbuffer.lightLayer,Gbuffer.edgeMask);
    
#if GBUFFERMATERIAL_COUNT > 4
    outGBufferE = Gbuffer.customData;
#endif
}

void DecodeFromGBuffer(GBufferTypeA inGBufferA
                        ,GBufferTypeB inGBufferB
                        ,GBufferTypeC inGBufferC
                        ,GBufferTypeD inGBufferD
                        ,GBufferTypeE inGBufferE
                        ,out GBufferData Gbuffer)
{
    Gbuffer = (GBufferData)0;

    Gbuffer.staticLighting = inGBufferA;
    Gbuffer.baseColor = inGBufferB.rgb;
    Gbuffer.shadowMask = inGBufferB.a;

    NormalData normalData = DecodeFromNormalBuffer(inGBufferC);
    Gbuffer.normalWS = normalData.normalWS;
    Gbuffer.ao = normalData.ao;

    Gbuffer.metallic = inGBufferD.r;
    Gbuffer.smoothness = inGBufferD.g;
    Gbuffer.customDataSingle = inGBufferD.b;
    uint3 modeAndLayer =  UnPackShadingModeAndLightLayer(inGBufferD.a);
    Gbuffer.shadingModelID = modeAndLayer.x;
    Gbuffer.lightLayer = modeAndLayer.y;
    Gbuffer.edgeMask = modeAndLayer.z;
    Gbuffer.customData = inGBufferE;
}


#endif // SOUL_GBUFFERUTIL_INCLUDED
