Shader "Hidden/SSProfile/DebugView"
{
    Properties
    {
        _MainTex ("Main Texture", 2D) = "white" {}
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" }

        Pass
        {
            Name "SSProfile Debug View"
            
            ZTest Always
            ZWrite Off
            Cull Off

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

            TEXTURE2D_X(_SSProfileSetupDiffuse);
            SAMPLER(sampler_SSProfileSetupDiffuse);

            TEXTURE2D_X(_SSProfileSetupSpecular);
            SAMPLER(sampler_SSProfileSetupSpecular);

            TEXTURE2D_X(_SSProfileScatteredDiffuse); 
            SAMPLER(sampler_SSProfileScatteredDiffuse);

            int _DebugMode;

            float3 TurboColormap(float t)
            {
                const float3 c0 = float3(0.1140, 0.0622, 0.2428);
                const float3 c1 = float3(6.7162, 3.9768, 2.3195);
                const float3 c2 = float3(-65.3134, -29.4273, -14.6871);
                const float3 c3 = float3(337.7518, 148.1354, 56.8034);
                const float3 c4 = float3(-647.8216, -272.0528, -80.0732);
                const float3 c5 = float3(448.8532, 179.2467, 39.9508);

                t = saturate(t);
                return saturate(c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * c5)))));
            }

            float4 frag(Varyings input) : SV_Target
            {
                float2 uv = input.texcoord;

                float4 diffuseDepth = SAMPLE_TEXTURE2D_X(_SSProfileSetupDiffuse, sampler_SSProfileSetupDiffuse, uv);
                float4 specularID = SAMPLE_TEXTURE2D_X(_SSProfileSetupSpecular, sampler_SSProfileSetupSpecular, uv);
                float4 scattered = SAMPLE_TEXTURE2D_X(_SSProfileScatteredDiffuse, sampler_SSProfileScatteredDiffuse, uv);

                float3 diffuse = diffuseDepth.rgb;
                float depth = diffuseDepth.a;
                float3 specular = specularID.rgb;
                float profileID = specularID.a;

                float3 output = 0;

                // Mode 0: Diffuse
                if (_DebugMode == 0)
                {
                    output = diffuse;
                    if (depth == 0.0) output = float3(0.1, 0.0, 0.0);
                }
                // Mode 1: Specular
                else if (_DebugMode == 1)
                {
                    output = specular;
                    if (depth == 0.0) output = float3(0.0, 0.1, 0.0);
                }
                // Mode 2: ProfileID
                else if (_DebugMode == 2)
                {
                    output = (depth > 0.0) ? TurboColormap(profileID) : float3(0.0, 0.0, 0.1);
                }
                // Mode 3: Depth
                else if (_DebugMode == 3)
                {
                    if (depth > 0.0)
                    {
                        float linearDepth = Linear01Depth(depth, _ZBufferParams);
                        output = linearDepth. xxx;
                    }
                    else
                    {
                        output = float3(1, 0, 0);
                    }
                }
                // Mode 4: TileMask
                else if (_DebugMode == 4)
                {
                    float hasSSSData = dot(diffuse, float3(0.333, 0.333, 0.333)) + dot(specular, float3(0.333, 0.333, 0.333));
                    output = (hasSSSData > 0.001) ? float3(0, 1, 0) : float3(0.05, 0.05, 0.05);
                    if (depth > 0.0) output.b = 0.3;
                }
                // Mode 5: Blur Comparison (Split Screen)
                else if (_DebugMode == 5)
                {
                    if (uv.x < 0.5)
                    {
                        // Left:  Before Blur
                        output = diffuse;
                    }
                    else
                    {
                        // Right: After Blur
                        output = scattered.rgb;
                    }
                    
                    if (abs(uv.x - 0.5) < 0.002)
                    {
                        output = float3(1, 1, 0); 
                    }
                }
                // ✅ Mode 6: Scattered Diffuse Only
                else if (_DebugMode == 6)
                {
                    output = scattered.rgb;
                    if (scattered.a == 0.0) output = float3(0.05, 0.05, 0.05);
                }

                return float4(output, 1.0);
            }

            ENDHLSL
        }
    }
}