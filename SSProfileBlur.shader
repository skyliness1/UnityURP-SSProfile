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
            #include "Packages/com.unity.render-pipelines.universal/ArtShaders/Scene/SSProfile/Shaders/Include/SSProfileDefines.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ArtShaders/Scene/SSProfile/Shaders/Include/SSProfileCommon.hlsl"
            
            TEXTURE2D_X(_BlitTexture);
            SAMPLER(sampler_BlitTexture);
            float4 _BlitScaleBias;
            
            TEXTURE2D_X(_GBufferTextureD);
            
            // x: sssScaleX (WorldScale * ProjDistance), y: ProjDistance, z: unused, w: quality
            float4 _SSSParams;      
            float4 _BlurDirection;
            float _DepthThreshold;
            float _DebugMode;
            
            // UE5 Constants
            #define SUBSURFACE_RADIUS_SCALE 1024.0
            #define SSSS_FOLLOW_SURFACE 1
            #define M_TO_CM 100.0  // Unity(m) -> UE5(cm) conversion
            
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
            
            float GetMaskFromDepthInAlpha(float alpha)
            {
                return alpha > 0 ? 1.0 : 0.0;
            }
            
            void GetSSSData(float2 uv, out uint profileId, out float opacity)
            {
                float4 GBufferD = SAMPLE_TEXTURE2D_X(_GBufferTextureD, sampler_PointClamp, uv);
                profileId = (uint)(GBufferD.b * 255.0 + 0.5);
                opacity = GBufferD.r; 
            }
            
            uint GetSubsurfaceProfileId(float2 uv)
            {
                float4 GBufferD = SAMPLE_TEXTURE2D_X(_GBufferTextureD, sampler_PointClamp, uv);
                return (uint)(GBufferD.b * 255.0 + 0.5);
            }

            half4 Frag(Varyings input) : SV_Target
            {
                float2 uv = input.uv;
                
                half4 colorM = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, uv);
                float OutDepth = colorM.a; // Linear Eye Depth in Meters
                
                colorM.a = GetMaskFromDepthInAlpha(colorM.a);
                
                // Skip non-SSS pixels
                if (colorM.a <= 0.0) return 0;
                
                uint profileId;
                float SSSStrength;
                GetSSSData(uv, profileId, SSSStrength);
                
                if (SSSStrength < 1.0 / 256.0) return half4(colorM.rgb, OutDepth);
                
                // ============================================================
                // FIXED: Scale Calculation
                // 1. Convert Depth to CM
                // 2. Clamp Minimum Depth to avoid division by zero
                // 3. Clamp Maximum Scale to avoid banding artifacts
                // ============================================================
                float DepthCM = max(OutDepth * M_TO_CM, 1.0); 
                float SSSScaleX = _SSSParams.x; 
                
                // UE5 Logic: Scale = SSSScaleX / Depth
                float scale = SSSScaleX / DepthCM;
                
                // CRITICAL FIX: Clamp max radius to avoid huge steps at close range (Image 3 fix)
                // 50.0 is an empirical value, roughly 5% of screen width max blur
                scale = min(scale, 50.0); 
                
                float2 finalStep = scale * _BlurDirection.xy * SSSStrength;
                
                uint quality = (uint)_SSSParams.w;
                uint kernelStartOffset, kernelSize;
                GetKernelOffsetAndSize(quality, kernelStartOffset, kernelSize);
                
                float3 BoundaryColorBleed = GetSubsurfaceProfileBoundaryBleed(profileId);
                
                float3 colorAccum = float3(0, 0, 0);
                float3 colorInvDiv = float3(0.00001, 0.00001, 0.00001);
                
                // Central Sample
                half3 CentralKernelWeight = GetSubsurfaceProfileKernelSample(profileId, quality, 0).rgb;
                colorInvDiv += CentralKernelWeight;
                colorAccum = colorM.rgb * CentralKernelWeight;
                
                UNITY_UNROLL
                for (uint i = 1; i < 13; i++)
                {
                    if (i >= kernelSize) break;
                    
                    float4 Kernel = GetSubsurfaceProfileKernelSample(profileId, quality, i);
                    
                    // UE5 Kernel.a is already scaled by 1024/Radius in Generator? No, usually generator stores Offset/1024
                    // So here we multiply by 1024 (SUBSURFACE_RADIUS_SCALE) to get back normalized offset
                    // Then multiply by finalStep
                    float2 UVOffset = Kernel.a * SUBSURFACE_RADIUS_SCALE * finalStep;
                    
                    float4 LocalAccum = float4(0, 0, 0, 0);
                    
                    UNITY_UNROLL
                    for (int Side = -1; Side <= 1; Side += 2)
                    {
                        float2 LocalUV = uv + UVOffset * Side;
                        // Clamp UV to avoid texture wrap bleeding
                        LocalUV = clamp(LocalUV, _BlitScaleBias.zw, _BlitScaleBias.zw + _BlitScaleBias.xy);
                        
                        float4 color = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, LocalUV);
                        uint LocalSubsurfaceProfileInt = GetSubsurfaceProfileId(LocalUV);
                        
                        float3 ColorTint = (LocalSubsurfaceProfileInt == profileId) ? float3(1, 1, 1) : BoundaryColorBleed;
                        float LocalDepth = color.a;
                        color.a = GetMaskFromDepthInAlpha(color.a);
                        
                        #if SSSS_FOLLOW_SURFACE
                        {
                            // FIXED: Depth Weighting
                            // Multiply depth diff by M_TO_CM because _SSSParams.y (ProjDistance) is calibrated for CM
                            float depthDiffCM = abs(OutDepth - LocalDepth) * M_TO_CM;
                            float s = saturate(12000.0 / 400000.0 * _SSSParams.y * depthDiffCM);
                            color.a *= 1.0 - s;
                        }
                        #endif
                        
                        color.rgb *= color.a * ColorTint;
                        LocalAccum += color;
                    }
                    
                    colorAccum += Kernel.rgb * LocalAccum.rgb;
                    colorInvDiv += Kernel.rgb * LocalAccum.a;
                }
                
                float3 OutColor = colorAccum / colorInvDiv;
                return half4(OutColor, OutDepth);
            }
            
            ENDHLSL
        }
    }
}