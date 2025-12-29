Shader "Soul/Scene/SSProfileSetup"
{
    Properties
    {
        // Blitter 使用 _BlitTexture
        [HideInInspector] _BlitTexture ("", 2D) = "white" {}
    }
    
    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" }
        
        Pass
        {
            Name "SSS Setup"
            ZTest Always 
            ZWrite Off 
            Cull Off
            
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment Frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueDepth.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SoulGBuffer.hlsl"
            
            // ============================================================
            // 关键：URP 14 Blitter 使用 _BlitTexture 和 _BlitScaleBias
            // ============================================================
            TEXTURE2D_X(_BlitTexture);
            SAMPLER(sampler_BlitTexture);
            float4 _BlitScaleBias;
            
            TEXTURE2D_X(_GBufferTextureD);
            
            float _DebugMode;
            
            struct Attributes
            {
                uint vertexID : SV_VertexID;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv :  TEXCOORD0;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                
                // Blitter 标准顶点着色器
                float4 pos = GetFullScreenTriangleVertexPosition(input.vertexID);
                float2 uv = GetFullScreenTriangleTexCoord(input.vertexID);
                
                output.positionCS = pos;
                output.uv = uv * _BlitScaleBias. xy + _BlitScaleBias.zw;
                
                return output;
            }
            
            bool IsCheckerboardEven(int2 pixelCoord)
            {
                return ((pixelCoord.x + pixelCoord.y) & 1) == 0;
            }
            
            float GetLinearDepth(float2 uv)
            {
                float rawDepth = SampleSceneDepth(uv);
                return LinearEyeDepth(rawDepth, _ZBufferParams);
            }

            half4 Frag(Varyings input) : SV_Target
            {
                float2 uv = input.uv;
                int2 pixelCoord = int2(uv * _ScreenSize. xy);
                
                // ============ Debug 1:  UV ============
                if (_DebugMode > 0.5 && _DebugMode < 1.5)
                {
                    return half4(uv. x, uv.y, 0, 1);
                }
                
                // 采样 GBufferD
                float4 GBufferD = SAMPLE_TEXTURE2D_X(_GBufferTextureD, sampler_PointClamp, uv);
                
                // ============ Debug 2: GBufferD. a ============
                if (_DebugMode > 1.5 && _DebugMode < 2.5)
                {
                    return half4(GBufferD.a, GBufferD.a, GBufferD.a, 1);
                }
                
                // 采样源纹理 (使用 _BlitTexture)
                half4 screenColor = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, uv);
                
                // ============ Debug 3: ScreenColor ============
                if (_DebugMode > 2.5 && _DebugMode < 3.5)
                {
                    return half4(screenColor. rgb, 1);
                }
                
                // 解包 ShadingModelID
                uint3 modeAndLayer = UnPackShadingModeAndLightLayer(GBufferD.a);
                uint shadingModelID = modeAndLayer. x;
                
                // ============ Debug 4: ShadingModelID ============
                if (_DebugMode > 3.5 && _DebugMode < 4.5)
                {
                    if (shadingModelID == 0) return half4(0.2, 0.2, 0.2, 1);
                    if (shadingModelID == 1) return half4(1, 0, 0, 1);
                    if (shadingModelID == 2) return half4(0, 1, 0, 1);
                    if (shadingModelID == 3) return half4(1, 1, 0, 1);
                    if (shadingModelID == 4) return half4(1, 0.5, 0, 1);
                    if (shadingModelID == 5) return half4(0, 0, 1, 1); // SSS = 蓝色
                    if (shadingModelID == 6) return half4(0, 1, 1, 1);
                    if (shadingModelID == 7) return half4(1, 0, 1, 1);
                    return half4(1, 1, 1, 1);
                }
                
                bool isSSS = (shadingModelID == SHADINGMODELID_SUBSURFACE_PROFILE);
                
                // ============ Debug 5: SSS Mask ============
                if (_DebugMode > 4.5 && _DebugMode < 5.5)
                {
                    return half4(isSSS ? 1 : 0, isSSS ? 1 : 0, isSSS ? 1 : 0, 1);
                }
                
                float linearDepth = GetLinearDepth(uv);
                
                // ============ Debug 6: Depth ============
                if (_DebugMode > 5.5 && _DebugMode < 6.5)
                {
                    float d = saturate(linearDepth / 50.0);
                    return half4(d, d, d, 1);
                }
                
                // ============ 正常逻辑 ============
                if (! isSSS)
                {
                    return half4(0, 0, 0, 0);
                }
                
                half3 diffuse;
                bool isDiffusePixel = IsCheckerboardEven(pixelCoord);
                
                if (isDiffusePixel)
                {
                    diffuse = screenColor.rgb;
                }
                else
                {
                    float2 texelSize = _ScreenSize.zw;
                    half3 neighbor = half3(0, 0, 0);
                    float count = 0;
                    
                    int2 offsets[4] = { int2(1,0), int2(-1,0), int2(0,1), int2(0,-1) };
                    
                    UNITY_UNROLL
                    for (int i = 0; i < 4; i++)
                    {
                        int2 nCoord = pixelCoord + offsets[i];
                        if (IsCheckerboardEven(nCoord))
                        {
                            float2 nUV = (float2(nCoord) + 0.5) * texelSize;
                            nUV = saturate(nUV);
                            
                            float4 nGBufferD = SAMPLE_TEXTURE2D_X(_GBufferTextureD, sampler_PointClamp, nUV);
                            uint3 nMode = UnPackShadingModeAndLightLayer(nGBufferD. a);
                            
                            if (nMode.x == SHADINGMODELID_SUBSURFACE_PROFILE)
                            {
                                neighbor += SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, nUV).rgb;
                                count += 1.0;
                            }
                        }
                    }
                    
                    diffuse = count > 0 ? neighbor / count : screenColor.rgb;
                }
                
                return half4(diffuse, linearDepth);
            }
            
            ENDHLSL
        }
    }
}