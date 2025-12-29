Shader "Soul/Scene/SSProfileBlur"
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
            Name "SSS Blur"
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
            
            TEXTURE2D_X(_GBufferTextureD);
            
            float4 _SSSParams;      // x: scale, y: projDistance, z: kernelSize, w: quality
            float4 _BlurDirection;
            float _DepthThreshold;
            float _DebugMode;
            
            // UE5: SUBSURFACE_RADIUS_SCALE = 1024, 用于缩放 Kernel 偏移
            #define SUBSURFACE_RADIUS_SCALE 1024.0
            
            // UE5: SSSS_FOLLOW_SURFACE = 1, 启用深度感知模糊
            #define SSSS_FOLLOW_SURFACE 1
            
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
                output.uv = uv * _BlitScaleBias. xy + _BlitScaleBias.zw;
                return output;
            }
            
            // UE5: GetMaskFromDepthInAlpha
            float GetMaskFromDepthInAlpha(float alpha)
            {
                return alpha > 0 ? 1.0 : 0.0;
            }
            
            // 获取 SSS 数据
            void GetSSSData(float2 uv, out uint profileId, out float opacity)
            {
                float4 GBufferD = SAMPLE_TEXTURE2D_X(_GBufferTextureD, sampler_PointClamp, uv);
                profileId = (uint)(GBufferD.b * 255.0 + 0.5);
                opacity = GBufferD.r;  // SSSStrength
            }
            
            // 获取 Profile ID
            uint GetSubsurfaceProfileId(float2 uv)
            {
                float4 GBufferD = SAMPLE_TEXTURE2D_X(_GBufferTextureD, sampler_PointClamp, uv);
                return (uint)(GBufferD.b * 255.0 + 0.5);
            }

            half4 Frag(Varyings input) : SV_Target
            {
                float2 uv = input.uv;
                
                // 采样中心像素 (Setup Pass 的输出:  RGB = Diffuse, A = Depth)
                half4 colorM = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, uv);
                
                // 保存原始深度用于输出
                float OutDepth = colorM.a;
                
                // UE5: 将深度转换为 Mask
                colorM.a = GetMaskFromDepthInAlpha(colorM.a);
                
                // 如果不是 SSS 像素，跳过
                if (!colorM.a)
                {
                    return half4(0, 0, 0, 0);
                }
                
                // 获取 SSSStrength (Opacity)
                uint profileId;
                float SSSStrength;
                GetSSSData(uv, profileId, SSSStrength);
                
                // 如果强度太低，返回原色
                if (SSSStrength < 1.0 / 256.0)
                {
                    return half4(colorM.rgb, OutDepth);
                }
                
                // ============================================================
                // UE5: 计算步长
                // scale = SSSScaleX / depth
                // finalStep = scale * dir * SSSStrength
                // ============================================================
                float SSSScaleX = _SSSParams.x;
                float scale = SSSScaleX / max(OutDepth, 0.001);
                
                // 计算最终步长
                float2 finalStep = scale * _BlurDirection.xy;
                
                // UE5: 使用 SSSStrength 调制步长
                finalStep *= SSSStrength;
                
                // 获取 Kernel 参数
                uint quality = (uint)_SSSParams.w;
                uint kernelStartOffset, kernelSize;
                GetKernelOffsetAndSize(quality, kernelStartOffset, kernelSize);
                
                // 获取边界颜色混合
                float3 BoundaryColorBleed = GetSubsurfaceProfileBoundaryBleed(profileId);
                
                // ============================================================
                // UE5 风格的累加:  按通道归一化
                // colorAccum / colorInvDiv (每个通道单独归一化)
                // ============================================================
                float3 colorAccum = float3(0, 0, 0);
                float3 colorInvDiv = float3(0.00001, 0.00001, 0.00001);  // 避免除零
                
                // 中心样本
                half3 CentralKernelWeight = GetSubsurfaceProfileKernelSample(profileId, quality, 0).rgb;
                colorInvDiv += CentralKernelWeight;
                colorAccum = colorM.rgb * CentralKernelWeight;
                
                // 累加其他样本
                UNITY_UNROLL
                for (uint i = 1; i < 13; i++)
                {
                    if (i >= kernelSize) break;
                    
                    // 获取 Kernel 数据
                    // UE5: Kernel. rgb = 权重, Kernel.a = 偏移 (已乘以 SUBSURFACE_RADIUS_SCALE)
                    float4 Kernel = GetSubsurfaceProfileKernelSample(profileId, quality, i);
                    
                    float4 LocalAccum = float4(0, 0, 0, 0);
                    
                    // UE5: UVOffset = Kernel.a * finalStep
                    float2 UVOffset = Kernel. a * finalStep;
                    
                    // 双向采样 (对称)
                    UNITY_UNROLL
                    for (int Side = -1; Side <= 1; Side += 2)
                    {
                        float2 LocalUV = uv + UVOffset * Side;
                        LocalUV = clamp(LocalUV, 0.001, 0.999);
                        
                        // 采样颜色和深度
                        float4 color = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, LocalUV);
                        
                        // 获取采样点的 Profile ID
                        uint LocalSubsurfaceProfileInt = GetSubsurfaceProfileId(LocalUV);
                        
                        // UE5: 边界颜色混合
                        float3 ColorTint = (LocalSubsurfaceProfileInt == profileId) ? float3(1, 1, 1) : BoundaryColorBleed;
                        
                        float LocalDepth = color.a;
                        color.a = GetMaskFromDepthInAlpha(color.a);
                        
                        // ============================================================
                        // UE5: SSSS_FOLLOW_SURFACE - 深度感知权重
                        // ============================================================
                        #if SSSS_FOLLOW_SURFACE
                        {
                            // UE5: s = saturate(12000. 0f / 400000 * SubsurfaceParams.y * abs(OutDepth - LocalDepth))
                            // SubsurfaceParams.y = DistanceToProjectionWindow
                            float s = saturate(12000.0 / 400000.0 * _SSSParams. y * abs(OutDepth - LocalDepth));
                            color.a *= 1.0 - s;
                        }
                        #endif
                        
                        // UE5: color.rgb *= color.a * ColorTint
                        // 这确保了非 SSS 像素和深度差异大的像素权重为 0
                        color.rgb *= color.a * ColorTint;
                        
                        // 累加左右样本
                        LocalAccum += color;
                    }
                    
                    // UE5: 使用相同权重累加左右样本
                    colorAccum += Kernel. rgb * LocalAccum.rgb;
                    colorInvDiv += Kernel.rgb * LocalAccum.a;
                }
                
                // ============================================================
                // UE5: 按通道归一化 (补偿被拒绝的样本)
                // ============================================================
                float3 OutColor = colorAccum / colorInvDiv;
                
                // 输出:  RGB = 模糊后的 Diffuse, A = 原始深度
                return half4(OutColor, OutDepth);
            }
            
            ENDHLSL
        }
    }
}