Shader "Soul/Scene/SSProfileRecombine"
{
    Properties
    {
        [HideInInspector] _MainTex ("Base", 2D) = "white" {}
    }
    
    HLSLINCLUDE
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SoulGBuffer.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ArtShaders/Scene/SSProfile/Shaders/Include/SSProfileCommon.hlsl"
    
    // 原始棋盘格纹理 (Global)
    TEXTURE2D(_Soul_ScreenColor);
    // sampler_PointClamp (Built-in)
    
    // 模糊后的 Diffuse
    TEXTURE2D(_SSSBlurredRT);
    // sampler_LinearClamp (Built-in)
    
    TEXTURE2D_X(_GBufferTextureD);
    float _DebugMode;
    
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
    
    void GetSSSData(float2 uv, out uint profileId, out float opacity)
    {
        float4 GBufferD = SAMPLE_TEXTURE2D_X(_GBufferTextureD, sampler_point_clamp, uv);
        profileId = (uint)(GBufferD.b * 255.0 + 0.5);
        opacity = GBufferD.r;
    }
    
    half3 SampleNeighborSpecular(float2 uv, int2 pixelCoord)
    {
        float2 texelSize = _ScreenSize.zw;
        float2 offsets[4] = { float2(1, 0), float2(-1, 0), float2(0, 1), float2(0, -1) };
        half3 result = 0;
        float count = 0;
        UNITY_UNROLL
        for (int i = 0; i < 4; i++)
        {
            int2 neighborCoord = pixelCoord + int2(offsets[i]);
            // 只有奇数像素包含 Specular
            if (!IsCheckerboardEven(neighborCoord)) 
            {
                float2 neighborUV = (neighborCoord + 0.5) * texelSize;
                // 必须用 Point 采样原始纹理
                result += SAMPLE_TEXTURE2D(_Soul_ScreenColor, sampler_PointClamp, neighborUV).rgb;
                count += 1.0;
            }
        }
        return count > 0 ? result / count : 0;
    }
    
    half3 SampleNeighborDiffuse(float2 uv, int2 pixelCoord)
    {
        float2 texelSize = _ScreenSize.zw;
        float2 offsets[4] = { float2(1, 0), float2(-1, 0), float2(0, 1), float2(0, -1) };
        half3 result = 0;
        float count = 0;
        UNITY_UNROLL
        for (int i = 0; i < 4; i++)
        {
            int2 neighborCoord = pixelCoord + int2(offsets[i]);
            if (IsCheckerboardEven(neighborCoord)) 
            {
                float2 neighborUV = (neighborCoord + 0.5) * texelSize;
                // 模糊图用 Linear 采样
                result += SAMPLE_TEXTURE2D(_SSSBlurredRT, sampler_LinearClamp, neighborUV).rgb;
                count += 1.0;
            }
        }
        return count > 0 ? result / count : 0;
    }

    half4 FragRecombine(Varyings input) : SV_Target
    {
        float2 uv = input.uv;
        int2 pixelCoord = int2(uv * _ScreenSize.xy);
        
        // 读取原始颜色 (必须用 PointClamp)
        half4 originalColor = SAMPLE_TEXTURE2D(_Soul_ScreenColor, sampler_PointClamp, uv);
        
        if (!IsSubsurfacePixel(uv))
        {
            return originalColor;
        }
        
        // Debug ...
        if (_DebugMode > 0.5) { /* 保留你的Debug逻辑 */ }
        
        uint profileId;
        float opacity;
        GetSSSData(uv, profileId, opacity);
        
        float3 tint;
        float worldUnitScale;
        GetSubsurfaceProfileTintAndScale(profileId, tint, worldUnitScale);
        
        half3 diffuse;
        half3 specular;
        
        bool isDiffusePixel = IsCheckerboardEven(pixelCoord);
        
        if (isDiffusePixel)
        {
            // 当前是 Diffuse 像素：取模糊后的结果
            diffuse = SAMPLE_TEXTURE2D(_SSSBlurredRT, sampler_LinearClamp, uv).rgb;
            // 邻居采样 Specular
            specular = SampleNeighborSpecular(uv, pixelCoord);
        }
        else
        {
            // 当前是 Specular 像素：取原始值
            specular = originalColor.rgb;
            // 邻居采样 Diffuse (模糊后)
            diffuse = SampleNeighborDiffuse(uv, pixelCoord);
        }
        
        half3 finalColor = diffuse * tint + specular;
        return half4(finalColor, 1);
    }

    ENDHLSL

    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" }
        Pass
        {
            Name "SSS Recombine"
            ZTest Always ZWrite Off Cull Off
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment FragRecombine
            ENDHLSL
        }
    }
}