Shader "Soul/Scene/SSProfileBlur"
{
    Properties
    {
        // 隐藏 MainTex，防止误用，我们使用全局纹理
        [HideInInspector] _MainTex ("Base", 2D) = "white" {}
    }
    
    HLSLINCLUDE
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueDepth.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SoulGBuffer.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ArtShaders/Scene/SSProfile/Shaders/Include/SSProfileCommon.hlsl"
    
    // 显式声明全局纹理
    TEXTURE2D(_Soul_ScreenColor);
    // 使用线性采样器 (Built-in)
    // sampler_LinearClamp
    
    TEXTURE2D_X(_GBufferTextureD);
    
    float4 _SSSParams;
    float4 _BlurDirection;
    float _DepthThreshold;
    int _DebugMode;
    
    struct Attributes
    {
        float4 positionOS : POSITION;
        float2 uv : TEXCOORD0;
    };

    struct Varyings
    {
        float4 positionCS : SV_POSITION;
        float2 uv : TEXCOORD0;
    };

    Varyings Vert(Attributes input)
    {
        Varyings output;
        output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
        output.uv = input.uv;
        return output;
    }
    
    bool IsCheckerboardEven(int2 pixelCoord)
    {
        return ((pixelCoord.x + pixelCoord.y) & 1) == 0;
    }

    uint GetShadingModelID(float2 uv)
    {
        float4 GBufferD = SAMPLE_TEXTURE2D_X(_GBufferTextureD, sampler_point_clamp, uv);
        uint3 modeAndLayer = UnPackShadingModeAndLightLayer(GBufferD.a);
        return modeAndLayer.x;
    }
    
    bool IsSubsurfacePixel(float2 uv)
    {
        return GetShadingModelID(uv) == SHADINGMODELID_SUBSURFACE_PROFILE;
    }
    
    float GetLinearDepth(float2 uv)
    {
        float rawDepth = SampleSceneDepth(uv);
        return LinearEyeDepth(rawDepth, _ZBufferParams);
    }
    
    float GetBilateralWeight(float centerDepth, float sampleDepth)
    {
        float depthDiff = abs(centerDepth - sampleDepth);
        float threshold = _DepthThreshold * centerDepth * 0.01;
        return exp(-depthDiff * depthDiff / (threshold * threshold + 0.0001));
    }
    
    void GetSSSData(float2 uv, out uint profileId, out float opacity)
    {
        float4 GBufferD = SAMPLE_TEXTURE2D_X(_GBufferTextureD, sampler_point_clamp, uv);
        profileId = (uint)(GBufferD.b * 255.0 + 0.5);
        opacity = GBufferD.r;
    }
    
    half4 FragBlur(Varyings input) : SV_Target
    {
        float2 uv = input.uv;
        
        // 修正：使用 _ScreenSize.xy (Width, Height) 计算像素坐标
        int2 pixelCoord = int2(uv * _ScreenSize.xy);
        
        // 修正：采样 _Soul_ScreenColor
        half4 centerSample = SAMPLE_TEXTURE2D(_Soul_ScreenColor, sampler_LinearClamp, uv);
        
        if (!IsSubsurfacePixel(uv)) return centerSample;
        
        // Specular 像素直接返回 (仅模糊 Diffuse)
        if (!IsCheckerboardEven(pixelCoord)) return centerSample;
        
        uint profileId;
        float opacity;
        GetSSSData(uv, profileId, opacity);
        
        float centerDepth = GetLinearDepth(uv);
        if (centerDepth > 1000.0) return centerSample;
        
        // 修正：使用 _ScreenSize.zw (1/W, 1/H) 作为 TexelSize
        float2 texelSize = _ScreenSize.zw;
        
        float sssScaleX = _SSSParams.x;
        float finalStep = sssScaleX / max(centerDepth, 0.001);
        float2 stepDir = _BlurDirection.xy * finalStep * texelSize * 2.0;
        
        uint quality = (uint)_SSSParams.w;
        uint kernelStartOffset, kernelSize;
        GetKernelOffsetAndSize(quality, kernelStartOffset, kernelSize);
        
        half3 colorAccum = half3(0, 0, 0);
        half3 weightAccum = half3(0, 0, 0);
        
        UNITY_UNROLL
        for (uint i = 0; i < 13; i++)
        {
            if (i >= kernelSize) break;
            
            float4 kernelData = GetSubsurfaceProfileKernelSample(profileId, quality, i);
            half3 kernelWeight = kernelData.rgb;
            float sampleOffset = kernelData.a;
            
            float2 sampleUV = uv + stepDir * sampleOffset;
            
            // 简单的棋盘格对齐校正
            int2 sampleCoord = int2(sampleUV * _ScreenSize.xy);
            if (!IsCheckerboardEven(sampleCoord))
            {
                sampleUV += _BlurDirection.xy * texelSize;
            }
            
            bool inBounds = all(sampleUV >= 0) && all(sampleUV <= 1);
            sampleUV = inBounds ? sampleUV : uv;
            
            // 修正：采样 _Soul_ScreenColor
            half4 sampleColor = SAMPLE_TEXTURE2D(_Soul_ScreenColor, sampler_LinearClamp, sampleUV);
            float sampleDepth = GetLinearDepth(sampleUV);
            
            bool isSSSPixel = IsSubsurfacePixel(sampleUV);
            
            float bilateralWeight = GetBilateralWeight(centerDepth, sampleDepth);
            bilateralWeight *= isSSSPixel ? 1.0 : 0.0;
            bilateralWeight *= inBounds ? 1.0 : 0.0;
            
            half3 finalWeight = kernelWeight * bilateralWeight;
            colorAccum += sampleColor.rgb * finalWeight;
            weightAccum += finalWeight;
        }
        
        half3 result = colorAccum / max(weightAccum, half3(0.0001, 0.0001, 0.0001));
        return half4(result, centerSample.a);
    }

    ENDHLSL

    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" }
        Pass
        {
            Name "SSS Blur"
            ZTest Always ZWrite Off Cull Off
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment FragBlur
            ENDHLSL
        }
    }
}