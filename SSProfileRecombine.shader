Shader "Soul/Scene/SSProfileRecombine"
{
    Properties
    {
        [HideInInspector] _BlitTexture ("", 2D) = "white" {}
    }
    
    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" }
        
        Pass
        {
            Name "SSS Recombine"
            ZTest Always 
            ZWrite Off 
            Cull Off
            
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment Frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SoulGBuffer.hlsl"
            #include "Packages/com.unity.render-pipelines.universal@14.0.11/ArtShaders/Scene/SSProfile/Shaders/Include/SSProfileDefines.hlsl"
            #include "Packages/com.unity.render-pipelines.universal@14.0.11/ArtShaders/Scene/SSProfile/Shaders/Include/SSProfileCommon.hlsl"
            
            TEXTURE2D_X(_BlitTexture);
            SAMPLER(sampler_BlitTexture);
            float4 _BlitScaleBias;
            
            TEXTURE2D(_SSS_ScreenColor);
            SAMPLER(sampler_SSS_ScreenColor);
            
            TEXTURE2D(_SSS_BlurredResult);
            SAMPLER(sampler_SSS_BlurredResult);
            
            TEXTURE2D_X(_GBufferTextureD);
            
            float _DebugMode;
            
            // UE5: ReconstructMethod 控制重建质量 (0-3)
            #define RECONSTRUCT_METHOD 3
            
            struct Attributes
            {
                uint vertexID : SV_VertexID;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                float4 pos = GetFullScreenTriangleVertexPosition(input.vertexID);
                float2 uv = GetFullScreenTriangleTexCoord(input.vertexID);
                output.positionCS = pos;
                output.uv = uv * _BlitScaleBias.xy + _BlitScaleBias.zw;
                return output;
            }
            
            bool IsSubsurfacePixel(float2 uv)
            {
                float4 GBufferD = SAMPLE_TEXTURE2D_X(_GBufferTextureD, sampler_PointClamp, uv);
                uint3 modeAndLayer = UnPackShadingModeAndLightLayer(GBufferD.a);
                return modeAndLayer.x == SHADINGMODELID_SUBSURFACE_PROFILE;
            }
            
            void GetSSSData(float2 uv, out uint profileId, out float opacity)
            {
                float4 GBufferD = SAMPLE_TEXTURE2D_X(_GBufferTextureD, sampler_PointClamp, uv);
                profileId = (uint)(GBufferD.b * 255.0 + 0.5);
                opacity = GBufferD. r;
            }
            
            // UE5: LookupSceneColor 带 SSS 验证
            half3 LookupSceneColor(float2 uv, int2 offset)
            {
                float2 sampleUV = uv + offset * _ScreenSize. zw;
                half3 color = SAMPLE_TEXTURE2D(_SSS_ScreenColor, sampler_SSS_ScreenColor, sampleUV).rgb;
                
                // 验证采样点是否是 SSS 像素
                bool bIsSubsurface = IsSubsurfacePixel(sampleUV);
                return bIsSubsurface ? color :  half3(0, 0, 0);
            }
            
            // UE5: ReconstructLighting - 从棋盘格重建 Diffuse 和 Specular
            void ReconstructLighting(float2 uv, out half3 Diffuse, out half3 Specular)
            {
                int2 pixelCoord = int2(uv * _ScreenSize.xy);
                bool bChecker = IsCheckerboardEven(pixelCoord);
                
                half3 Quant0 = SAMPLE_TEXTURE2D(_SSS_ScreenColor, sampler_SSS_ScreenColor, uv).rgb;
                half3 Quant1;
                
                #if RECONSTRUCT_METHOD == 0
                    // 快速但可能有图案
                    Quant1 = LookupSceneColor(uv, int2(1, 0));
                    
                #elif RECONSTRUCT_METHOD == 1
                    // 可接受的质量
                    Quant1 = 0.5 * (
                        LookupSceneColor(uv, int2(1, 0)) +
                        LookupSceneColor(uv, int2(-1, 0)));
                    
                #elif RECONSTRUCT_METHOD == 2
                    // 4 方向平均
                    Quant1 = 0.25 * (
                        LookupSceneColor(uv, int2(1, 0)) +
                        LookupSceneColor(uv, int2(0, 1)) +
                        LookupSceneColor(uv, int2(-1, 0)) +
                        LookupSceneColor(uv, int2(0, -1)));
                    
                #elif RECONSTRUCT_METHOD == 3
                    // UE5: 最佳质量 - 自适应选择
                    half3 A = LookupSceneColor(uv, int2(1, 0));
                    half3 B = LookupSceneColor(uv, int2(-1, 0));
                    half3 C = LookupSceneColor(uv, int2(0, 1));
                    half3 D = LookupSceneColor(uv, int2(0, -1));
                    
                    float a = Luminance(A);
                    float b = Luminance(B);
                    float c = Luminance(C);
                    float d = Luminance(D);
                    
                    float ab = abs(a - b);
                    float cd = abs(c - d);
                    
                    // 选择变化较小的方向
                    Quant1 = 0.5 * lerp(A + B, C + D, ab > cd);
                #endif
                
                // 棋盘格解码:  偶数像素 = Diffuse, 奇数像素 = Specular
                Diffuse = bChecker ? Quant0 :  Quant1;
                Specular = bChecker ? Quant1 : Quant0;
            }

            half4 Frag(Varyings input) : SV_Target
            {
                float2 uv = input.uv;
                
                // 采样原始场景颜色
                half4 originalColor = SAMPLE_TEXTURE2D(_SSS_ScreenColor, sampler_SSS_ScreenColor, uv);
                
                // 非 SSS 像素:  直接返回原始颜色
                if (!IsSubsurfacePixel(uv))
                {
                    return originalColor;
                }
                
                // 获取 SSS 数据
                uint profileId;
                float opacity;
                GetSSSData(uv, profileId, opacity);
                
                // 获取 Tint
                float3 tint;
                float worldUnitScale;
                GetSubsurfaceProfileTintAndScale(profileId, tint, worldUnitScale);
                
                // UE5: 重建 Diffuse 和 Specular
                half3 reconstructedDiffuse;
                half3 reconstructedSpecular;
                ReconstructLighting(uv, reconstructedDiffuse, reconstructedSpecular);
                
                // 采样模糊后的 Diffuse
                half4 blurredData = SAMPLE_TEXTURE2D(_SSS_BlurredResult, sampler_SSS_BlurredResult, uv);
                half3 blurredDiffuse = blurredData.rgb;
                
                // ============================================================
                // UE5: 最终合成
                // FinalColor = BlurredDiffuse * Tint * BaseColor + Specular
                // ============================================================
                
                // 应用 Tint 到模糊后的 Diffuse
                half3 tintedDiffuse = blurredDiffuse * tint;
                
                // 最终颜色 = 散射后的 Diffuse + 原始 Specular
                half3 finalColor = tintedDiffuse + reconstructedSpecular;
                
                return half4(finalColor, 1);
            }
            
            ENDHLSL
        }
    }
}