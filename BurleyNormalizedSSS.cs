using UnityEngine;
using UnityEngine.Experimental.GlobalIllumination;

using UnityGLTF.Extensions;

namespace SoulRender
{
    public class BurleyNormalizedSSS
    {
        public const float UE_PI = 3.1415926535897932f;
        public const float ProfileRadiusOffset = 0.06f;
        public const float Dmfp2MfpMagicNumber = 0.6f;
        public const float CmToMm = 10.0f;
        public const float MmToCm = 0.1f;

        public static float Burley_ScatteringProfile(float r, float A, float S, float L)
        {
            if (S <= 1e-6f || L <= 1e-6f)
            {
                return 0.0f;
            }
            float D = 1.0f / S;
            float R = r / L;
            const float Inv8Pi = 1.0f / (8.0f * UE_PI);
            float NegRbyD = -R / D;
            float expTerm = Mathf.Exp(NegRbyD) + Mathf.Exp(NegRbyD / 3.0f);
            return A * Mathf.Max(expTerm / (D * L) * Inv8Pi, 0.0f);
        }

        public static float Burley_TransmissionProfile(float r, float A, float S, float L)
        {
            if (L <= 1e-6f)
            {
                return 0.0f;
            }
            
            float term1 = Mathf.Exp(-S * r / L);
            float term2 = 3.0f * Mathf. Exp(-S * r / (3.0f * L));
            return 0.25f * A * (term1 + term2);
        }

        public static Vector3 Burley_ScatteringProfile(float radiusInMm, Color surfaceAlbedo, Vector3 scalingFactor, Color diffuseMeanFreePathInMm)
        {
            return new Vector3(
                Burley_ScatteringProfile(radiusInMm, surfaceAlbedo.r, scalingFactor.x, diffuseMeanFreePathInMm.r),
                Burley_ScatteringProfile(radiusInMm, surfaceAlbedo.g, scalingFactor.y, diffuseMeanFreePathInMm.g),
                Burley_ScatteringProfile(radiusInMm, surfaceAlbedo.b, scalingFactor.z, diffuseMeanFreePathInMm.b)
            );
        }

        public static Color Burley_TransmissionProfile(float radiusInMm, Color surfaceAlbedo, Vector3 scalingFactor, Color diffuseMeanFreePathInMm)
        {
            return new Color(
                Burley_TransmissionProfile(radiusInMm, surfaceAlbedo.r, scalingFactor.x, diffuseMeanFreePathInMm.r),
                Burley_TransmissionProfile(radiusInMm, surfaceAlbedo.g, scalingFactor.y, diffuseMeanFreePathInMm.g),
                Burley_TransmissionProfile(radiusInMm, surfaceAlbedo.b, scalingFactor.z, diffuseMeanFreePathInMm.b),
                1.0f
            );
        }

        //Map burley ColorFallOff to Burley SurfaceAlbedo and diffuse mean free path.
        public static void MapFallOffColor2SurfaceAlbedoAndDiffuseMeanFreePath(float falloffColor, out float surfaceAlbedo,
            out float diffuseMeanFreePath)
        {
            float X = falloffColor;
            float X2 = X * X;
            float X4 = X2 * X2;
            surfaceAlbedo = 0.906f * X + 0.00004f;
            diffuseMeanFreePath = 10.39f * X4 + X - 15.18f * X4 + 8.332f * X2 * X - 2.039f * X2 + 0.7279f * X - 0.0014f;
        }
        
        //-----------------------------------------------------------------
        // Functions should be identical on both cpu and gpu
        // Method 1: The light directly goes into the volume in a direction perpendicular to the surface.
        // Average relative error: 5.5% (reference to MC)
        public static float GetPerpendicularScalingFactor(float surfaceAlbedo)
        {
            return 1.85f - surfaceAlbedo + 7.0f * Mathf.Pow(Mathf.Abs(surfaceAlbedo - 0.8f), 3.0f);
        }
        
        public static Vector3 GetPerpendicularScalingFactor(Color surfaceAlbedo)
        {
            return new Vector3(
                GetPerpendicularScalingFactor(surfaceAlbedo.r),
                GetPerpendicularScalingFactor(surfaceAlbedo.g),
                GetPerpendicularScalingFactor(surfaceAlbedo.b)
            );
        }

        // Method 2: Ideal diffuse transmission at the surface. More appropriate for rough surface.
        // Average relative error: 3.9% (reference to MC)
        public static float GetDiffuseSurfaceScalingFactor(float surfaceAlbedo)
        {
            return 1.9f - surfaceAlbedo + 3.5f * Mathf.Pow(surfaceAlbedo - 0.8f, 2f);
        }

        public static Vector3 GetDiffuseSurfaceScalingFactor(Color surfaceAlbedo)
        {
            return new Vector3(
                GetDiffuseSurfaceScalingFactor(surfaceAlbedo.r),
                GetDiffuseSurfaceScalingFactor(surfaceAlbedo.g),
                GetDiffuseSurfaceScalingFactor(surfaceAlbedo.b));
        }
        
        // Method 3: The spectral of diffuse mean free path on the surface.
        // Avergate relative error: 7.7% (reference to MC)
        public static float GetSearchLightDiffuseScalingFactor(float surfaceAlbedo)
        {
            return 3.5f + 100.0f * Mathf. Pow(surfaceAlbedo - 0.33f, 4.0f);
        }

        public static Vector3 GetSearchLightDiffuseScalingFactor(Color surfaceAlbedo)
        {
            return new Vector3(
                GetSearchLightDiffuseScalingFactor(surfaceAlbedo.r),
                GetSearchLightDiffuseScalingFactor(surfaceAlbedo.g),
                GetSearchLightDiffuseScalingFactor(surfaceAlbedo.b)
            );
        }
        
        public static Color GetMeanFreePathFromDiffuseMeanFreePath(Color surfaceAlbedo, Color diffuseMeanFreePath)
        {
            surfaceAlbedo = surfaceAlbedo.linear;
            diffuseMeanFreePath = diffuseMeanFreePath.linear;
            
            Vector3 s_search = GetSearchLightDiffuseScalingFactor(surfaceAlbedo);
            Vector3 s_perp = GetPerpendicularScalingFactor(surfaceAlbedo);

            return new Color(
                diffuseMeanFreePath.r * (s_perp.x / s_search.x),
                diffuseMeanFreePath.g * (s_perp.y / s_search.y),
                diffuseMeanFreePath.b * (s_perp.z / s_search.z),
                1.0f
            );
        }
        
        public static Color GetDiffuseMeanFreePathFromMeanFreePath(Color surfaceAlbedo, Color meanFreePath)
        {
            Debug.Log($"[Burley] Input SurfaceAlbedo (gamma): R={surfaceAlbedo.r:F4}, G={surfaceAlbedo.g:F4}, B={surfaceAlbedo.b:F4}");
    
            surfaceAlbedo = surfaceAlbedo.linear;
            meanFreePath = meanFreePath.linear;
    
            Debug.Log($"[Burley] Input SurfaceAlbedo (linear): R={surfaceAlbedo.r:F4}, G={surfaceAlbedo.g:F4}, B={surfaceAlbedo.b:F4}");
            Debug.Log($"[Burley] Input MFP (cm, linear): R={meanFreePath.r:F4}, G={meanFreePath.g:F4}, B={meanFreePath.b:F4}");
    
            Vector3 s_search = GetSearchLightDiffuseScalingFactor(surfaceAlbedo);
            Vector3 s_perp = GetPerpendicularScalingFactor(surfaceAlbedo);
    
            Debug.Log($"[Burley] s_search: ({s_search.x:F4}, {s_search. y:F4}, {s_search.z:F4})");
            Debug.Log($"[Burley] s_perp: ({s_perp.x:F4}, {s_perp.y:F4}, {s_perp.z:F4})");

            Color result = new Color(
                meanFreePath.r * (s_search.x / s_perp.x),
                meanFreePath.g * (s_search.y / s_perp.y),
                meanFreePath.b * (s_search.z / s_perp.z),
                1.0f
            );
    
            Debug.Log($"[Burley] Output DMFP (cm): R={result.r:F4}, G={result.g:F4}, B={result.b:F4}");
    
            return result;
        }
        
        // ============================================================================
        // Subsurface Kernel 计算
        // ============================================================================
        
        public static void ComputeMirroredBSSSKernel(Color[] targetBuffer, int targetBufferSize,
            Color surfaceAlbedo, Color diffuseMeanFreePath, float scatterRadius)
        {
            // ✅ 调试输入
            Debug.Log($"[Kernel] Input SurfaceAlbedo:  R={surfaceAlbedo. r:F4}, G={surfaceAlbedo.g:F4}, B={surfaceAlbedo.b:F4}");
            Debug.Log($"[Kernel] Input DMFP (mm): R={diffuseMeanFreePath.r:F4}, G={diffuseMeanFreePath.g:F4}, B={diffuseMeanFreePath.b:F4}");
            Debug.Log($"[Kernel] Input ScatterRadius (cm): {scatterRadius:F4}");
            
            if (targetBuffer == null)
            {
                return;
            }

            if (targetBufferSize <= 0)
            {
                return;
            }

            targetBuffer.ToLinear();
            surfaceAlbedo = surfaceAlbedo.linear;
            diffuseMeanFreePath = diffuseMeanFreePath.linear;

            int nNonMirroredSamples = targetBufferSize;
            int nTotalSamples = nNonMirroredSamples * 2 - 1;

            if (nTotalSamples >= 64)
            {
                nTotalSamples = 63;
            }

            Vector3 scalingFactor = GetSearchLightDiffuseScalingFactor(surfaceAlbedo);
            Color[] kernel = new Color[64];

            float Range = (nTotalSamples > 20) ? 3.0f : 2.0f;
            const float Exponent = 2.0f;

            // 1. Calculate the offsets
            float step = 2.0f * Range / (nTotalSamples - 1);
            for (int i = 0; i < nTotalSamples; i++)
            {
                float o = -Range + (float)i * step;
                float sign = o < 0.0f ? -1.0f : 1.0f;
                float val = Range * sign * Mathf.Abs(Mathf.Pow(o, Exponent)) / Mathf.Pow(Range, Exponent);
                kernel[i].a = val;
            }
            
            // 强制中心为 0
            int centerIndex = nTotalSamples / 2;
            kernel[centerIndex].a = 0.0f;
            
            float SpaceScale = scatterRadius * CmToMm; 

            for (int i = 0; i < nTotalSamples; i++)
            {
                float w0 = i > 0 ?  Mathf.Abs(kernel[i].a - kernel[i - 1].a) : 0.0f;
                float w1 = i < nTotalSamples - 1 ? Mathf.Abs(kernel[i].a - kernel[i + 1].a) : 0.0f;
                float area = (w0 + w1) / 2.0f;
                float r = Mathf.Abs(kernel[i].a) * SpaceScale;
                Vector3 t = area * Burley_ScatteringProfile(r, surfaceAlbedo, scalingFactor, diffuseMeanFreePath);
                kernel[i].r = t.x;
                kernel[i].g = t.y;
                kernel[i].b = t.z;
            }

            // 3. Multiply offset by 2.0 (step scale)
            for (int i = 0; i < nTotalSamples; i++)
            {
                kernel[i].a *= 2.0f;
            }

            // 4. 重排序:  中心点移到 [0]
            Color centerPixel = kernel[centerIndex];
            
            for (int i = centerIndex; i > 0; i--)
            {
                kernel[i] = kernel[i - 1];
            }
            kernel[0] = centerPixel;

            // 5. 归一化 RGB
            Vector3 sum = Vector3.zero;
            for (int i = 0; i < nTotalSamples; i++)
            {
                sum.x += kernel[i].r;
                sum.y += kernel[i].g;
                sum.z += kernel[i].b;
            }

            for (int i = 0; i < nTotalSamples; i++)
            {
                if (sum.x > 1e-6f)
                {
                    kernel[i].r /= sum. x;
                }

                if (sum.y > 1e-6f)
                {
                    kernel[i].g /= sum.y;
                }

                if (sum.z > 1e-6f)
                {
                    kernel[i].b /= sum.z;
                }
            }

            // 6. 输出 (center + positive samples)
            targetBuffer[0] = kernel[0];
            for (int i = 0; i < nNonMirroredSamples - 1; i++)
            {
                targetBuffer[i + 1] = kernel[nNonMirroredSamples + i];
            }
        }

        // ============================================================================
        // Transmission Profile 计算
        // ============================================================================
        
        public static void ComputeTransmissionProfileBurley(
            Color[] targetBuffer, int targetBufferSize, float extinctionScale,
            Color surfaceAlbedo, Color diffuseMeanFreePathInMm,
            float worldUnitScale, Color transmissionTintColor, bool useLegacy)
        {
            if (targetBuffer == null)
            {
                return;
            }

            if (targetBufferSize <= 0)
            {
                return;
            }

            targetBuffer.ToLinear();
            surfaceAlbedo = surfaceAlbedo.linear;
            diffuseMeanFreePathInMm = diffuseMeanFreePathInMm.linear;
            transmissionTintColor = transmissionTintColor.linear;
            
            
            // Unit scale should be independent to the base unit.
            // Example of scaling
            // ----------------------------------------
            // DistanceCm * UnitScale * CmToMm = Value (mm)
            // ----------------------------------------
            //   1          0.1         10     =   1mm
            //   1          1.0         10     =  10mm
            //   1         10.0         10     = 100mm
            
            const float SubsurfaceScatteringUnitInCm = 0.1f;
            float UnitScale = worldUnitScale / SubsurfaceScatteringUnitInCm;
            float InvUnitScale = 1.0f / UnitScale; // Scaling the unit is equivalent to inverse scaling of the profile.

            // Legacy 模式
            if (useLegacy)
            {
                InvUnitScale *= 0.1f;
            }

            const float MaxTransmissionProfileDistance = 5.0f;
            
            Vector3 ScalingFactor = GetSearchLightDiffuseScalingFactor(surfaceAlbedo);

            float InvSize = 1.0f / targetBufferSize;

            for (int i = 0; i < targetBufferSize; ++i)
            {
                float DistanceInMm = i * InvSize * (MaxTransmissionProfileDistance * CmToMm) * InvUnitScale;
                float OffsetInMm = (ProfileRadiusOffset * CmToMm) * InvUnitScale;

                Color TransmissionProfile = Burley_TransmissionProfile(
                    DistanceInMm + OffsetInMm, 
                    surfaceAlbedo, 
                    ScalingFactor, 
                    diffuseMeanFreePathInMm);

                targetBuffer[i] = TransmissionProfile * transmissionTintColor;
                targetBuffer[i].a = Mathf.Exp(-DistanceInMm * extinctionScale);
            }

            // 强制最后一个像素为黑
            if (targetBufferSize > 0)
            {
                targetBuffer[targetBufferSize - 1] = Color.black;
            }
        }
    }
}
