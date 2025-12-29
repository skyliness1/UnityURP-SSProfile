#ifndef SOUL_DEFERRED_LIGHTING_PASS_INCLUDE
#define SOUL_DEFERRED_LIGHTING_PASS_INCLUDE

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueDepth.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SoulGBuffer.hlsl"
#include "Packages/com.unity.render-pipelines.universal/Shaders/Utils/SoulDeferredLightingCommon.hlsl"
// [MF][neilwei] - 压暗场景功能接入
#include "Packages/com.unity.render-pipelines.universal/Shaders/Soul/TA/DarkScene/DarkScene.hlsl"
#include "Packages/com.unity.render-pipelines.universal/Shaders/Soul/TA/SignalZone/SignalZone.hlsl"
#include "Packages/com.unity.render-pipelines.universal/Shaders/Soul/TA/AdaptiveExposure/AdaptiveExposure.hlsl"

// [MF] - 场景描边功能接入
#include "Packages/com.unity.render-pipelines.universal/Shaders/Soul/TA/SceneEdgeDetect/SceneEdgeDetect.hlsl"

struct Attributes
{
    uint vertexID : SV_VertexID;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct Varyings
{
    float4 positionCS : SV_POSITION;
    UNITY_VERTEX_OUTPUT_STEREO
};

struct Outputs
{
    float4 finalLighting : SV_Target0;
    #if defined(SNOW_SSS)
    float3 sssDiffuse : SV_Target1;
    #endif
};

#if defined(DEBUG_DISPLAY)
bool DebugGbufferData(GBufferData GBuffer, out float4 debugColor)
{
    // Debug materials...
    switch(_DebugMaterialMode)
    {
    case DEBUGMATERIALMODE_NONE:
        return false;

    case DEBUGMATERIALMODE_ALBEDO:
        debugColor = half4(GBuffer.baseColor, 1);
        return true;

    // case DEBUGMATERIALMODE_SPECULAR:
    //     debugColor = half4(surfaceData.specular, 1);
    //     return true;

    // case DEBUGMATERIALMODE_ALPHA:
    //     debugColor = half4(surfaceData.alpha.rrr, 1);
    //     return true;

    case DEBUGMATERIALMODE_SMOOTHNESS:
        debugColor = half4(GBuffer.smoothness.rrr, 1);
        return true;

    case DEBUGMATERIALMODE_AMBIENT_OCCLUSION:
        debugColor = half4(GBuffer.ao.rrr, 1);
        return true;

    // case DEBUGMATERIALMODE_EMISSION:
    //     debugColor = half4(surfaceData.emission, 1);
    //     return true;

    case DEBUGMATERIALMODE_NORMAL_WORLD_SPACE:
        debugColor = half4(GBuffer.normalWS.xyz * 0.5 + 0.5, 1);
        return true;

    // case DEBUGMATERIALMODE_NORMAL_TANGENT_SPACE:
    //     debugColor = half4(surfaceData.normalTS.xyz * 0.5 + 0.5, 1);
    //     return true;

    case DEBUGMATERIALMODE_METALLIC:
        debugColor = half4(GBuffer.metallic.rrr, 1);
        return true;

    default:
        debugColor = 1.0;
        return false;
    }
}
#endif

Varyings Vert(Attributes input)
{
    Varyings output;
    UNITY_SETUP_INSTANCE_ID(input);
    output.positionCS = GetFullScreenTriangleVertexPosition(input.vertexID);
    return output;
}


    //GBuffer
    TEXTURE2D_X(_GBufferTextureA);
    TEXTURE2D_X(_GBufferTextureB);
    TEXTURE2D_X(_GBufferTextureC);
    TEXTURE2D_X(_GBufferTextureD);
    //TEXTURE2D_X(_GBufferTextureE);

    TEXTURE2D_X(_CameraDepthAttachment);
#if defined(SNOW_SSS)
TEXTURE2D_FLOAT(_SnowMaskTex);
#endif

Outputs Frag(Varyings input)
{
    // input.positionCS is SV_Position
    //float depth = LoadSceneDepth(input.positionCS.xy);
    float depth =LOAD_TEXTURE2D_X_LOD(_CameraDepthAttachment, input.positionCS.xy, 0).r;

    PositionInputs posInput = GetPositionInput(input.positionCS.xy, _ScreenSize.zw, depth, UNITY_MATRIX_I_VP, UNITY_MATRIX_V,uint2(input.positionCS.xy) / GetTileSize());
    float3 viewDirectionWS = GetWorldSpaceViewDir(posInput.positionWS);
    float3 viewDirectionWSNormalized = normalize(viewDirectionWS);
    //Load GBuffer
    GBufferTypeA inGBufferA = LOAD_TEXTURE2D_X(_GBufferTextureA, posInput.positionSS);
    GBufferTypeB inGBufferB = LOAD_TEXTURE2D_X(_GBufferTextureB, posInput.positionSS);
    GBufferTypeC inGBufferC = LOAD_TEXTURE2D_X(_GBufferTextureC, posInput.positionSS);
    GBufferTypeD inGBufferD = LOAD_TEXTURE2D_X(_GBufferTextureD, posInput.positionSS);
    GBufferTypeE inGBufferE = 0;//LOAD_TEXTURE2D_X(_GBufferTextureE, posInput.positionSS);
    
    GBufferData GBuffer;
    DECODE_FROM_GBUFFER(inGBufferA,inGBufferB,inGBufferC,inGBufferD,inGBufferE,GBuffer);
    
    float4 finalLighting = 0;
    finalLighting.a = 1.0;
    
    //Lighting
    LightAccumulator lightAccumulator = AccumulateLighting(GBuffer,posInput,viewDirectionWSNormalized);
    finalLighting.rgb += lightAccumulator.totalLight;
    
    //场景描边
    UNITY_BRANCH
    if(GBuffer.edgeMask < 1)
    {
        finalLighting.rgb = SceneEdgeColor(GBuffer.edgeMask, GBuffer.shadingModelID, finalLighting.rgb,
            _GBufferTextureC, _CameraDepthAttachment, posInput.positionSS, input.positionCS.xy, viewDirectionWS, _GBufferTextureD);
    }
    

    #if !defined(_ATMOSPHERE)
    if (VolumeFogIntensity < 1.0)
    {
        //UE4高度雾
        float2 fogData = GetExponentialHeightFogFactor(-viewDirectionWS);
        float4 fogCoord = GetExponentialHeightFogColor(-viewDirectionWSNormalized, fogData.x, fogData.y);
        
        if (GBuffer.shadingModelID == SHADINGMODELID_UNLIT)
        {
            finalLighting.rgb = lerp(MixFogExp(finalLighting.rgb, fogCoord), finalLighting.rgb, GBuffer.ao);
        }
        else
        {
            finalLighting.rgb = MixFogExp(finalLighting.rgb, fogCoord);
        }
    }
    #endif
        
    
    //压暗场景颜色 -neilwei
    UNITY_BRANCH
    if (_Scene_Darked_On > 0)
        finalLighting.rgb = DarkSceneColor(finalLighting.rgb, posInput.positionWS);
    
    //毒圈内场景颜色
    UNITY_BRANCH
    if (_SignalZone_On > 0)
    {
        finalLighting.rgb = SignalZoneDarken(finalLighting.rgb, posInput.positionWS, GBuffer.normalWS);
    }
    //场景自动曝光
    UNITY_BRANCH
    if (_AdaptiveExposure_Enabled > 0)
    {
        AdaptiveExposure(finalLighting.rgb);
    }
    
    Outputs outputs;
    outputs.finalLighting = finalLighting;

    #if defined(DEBUG_DISPLAY)
    half4 debugColor;
    if(DebugGbufferData(GBuffer,debugColor))
    {
        outputs.finalLighting = debugColor;
    }
    #endif
    
    #if defined(SNOW_SSS)
    float2 uv = saturate((posInput.positionWS.xz + 1024.0) / 2048.0);
    float snowMask01 = SAMPLE_TEXTURE2D_LOD(_SnowMaskTex, sampler_LinearClamp, uv, 0).r;
    if(snowMask01 >= 0.112) // _SnowMaskThreshold
    {
        outputs.sssDiffuse = finalLighting;
        outputs.sssDiffuse.b = max(finalLighting.b, 1e-5);
    }
    else
    {
        outputs.sssDiffuse = float3(0,0,0);
    }
    #endif  
    
    return outputs;
}

#endif //SOUL_DEFERRED_LIGHTING_PASS_INCLUDE
