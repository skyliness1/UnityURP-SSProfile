Shader "Hidden/SSProfile/Recombine"
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
            Name "SSProfile Recombine"
            
            ZTest Always
            ZWrite Off
            Cull Off

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment frag
            #pragma target 3.5

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

            // ================================================================
            // 输入纹理
            // ================================================================

            TEXTURE2D_X(_SSProfileScatteredDiffuse);   // Blur Pass 输出
            SAMPLER(sampler_SSProfileScatteredDiffuse);

            TEXTURE2D_X(_SSProfileSetupSpecular);      // Setup Pass 输出（高光）
            SAMPLER(sampler_SSProfileSetupSpecular);

            TEXTURE2D_X(_TempColorAttachment);          // 原始场景颜色（非 SSS 像素用）
            SAMPLER(sampler_TempColorAttachment);

            float _SSS_Intensity;  // SSS 强度调节（可选）

            float4 frag(Varyings input) : SV_Target
            {
                float2 uv = input.texcoord;
                
                float4 scatteredData = SAMPLE_TEXTURE2D_X(
                    _SSProfileScatteredDiffuse, 
                    sampler_SSProfileScatteredDiffuse, 
                    uv
                );

                float3 scatteredDiffuse = scatteredData.rgb;
                float depth = scatteredData.a; 

             
                float3 specular = SAMPLE_TEXTURE2D_X(
                    _SSProfileSetupSpecular, 
                    sampler_SSProfileSetupSpecular, 
                    uv
                ).rgb;
                
                float3 originalColor = SAMPLE_TEXTURE2D_X(
                    _TempColorAttachment, 
                    sampler_TempColorAttachment, 
                    uv
                ).rgb;
                
                bool isSSS = (depth > 0.0);
                
                float3 finalColor;

                if (isSSS)
                {
                    finalColor = scatteredDiffuse + specular;
                }
                else
                {
                    finalColor = originalColor;
                }

                return float4(finalColor, 1.0);
            }

            ENDHLSL
        }
    }
}