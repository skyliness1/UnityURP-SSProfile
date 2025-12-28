using System. Collections;
using System.Collections.Generic;
using UnityEngine;

namespace SoulRender
{
    public class BurleyNormalizedSSS
    {
        public const float UE_PI = 3.1415926535897932f;
        public const float ProfileRadiusOffset = 0.06f;
        
        // UE5 魔法数字：用于 MFP 和 DMFP 之间的转换
        public const float Dmfp2MfpMagicNumber = 0.6f;
        
        // 单位转换常量
        public const float CmToMm = 10.0f;
        public const float MmToCm = 0.1f;

        // ==============================================================================
        // Scaling & Conversion Helpers
        // ==============================================================================
        
        /// <summary>
        /// Method 1: The light directly goes into the volume in a direction perpendicular to the surface.
        /// Average relative error: 5.5% (reference to MC)
        /// </summary>
        public static float GetPerpendicularScalingFactor(float SurfaceAlbedo)
        {
            // 1. 85 - SurfaceAlbedo + 7 * Pow(Abs(SurfaceAlbedo - 0.8), 3)
            return 1.85f - SurfaceAlbedo + 7.0f * Mathf.Pow(Mathf.Abs(SurfaceAlbedo - 0.8f), 3.0f);
        }

        public static Vector3 GetPerpendicularScalingFactor(Color SurfaceAlbedo)
        {
            return new Vector3(
                GetPerpendicularScalingFactor(SurfaceAlbedo.r),
                GetPerpendicularScalingFactor(SurfaceAlbedo.g),
                GetPerpendicularScalingFactor(SurfaceAlbedo.b)
            );
        }

        /// <summary>
        /// Method 3: The spectral of diffuse mean free path on the surface.
        /// Average relative error: 7.7% (reference to MC)
        /// </summary>
        public static float GetSearchLightDiffuseScalingFactor(float SurfaceAlbedo)
        {
            // 3.5 + 100 * Pow(SurfaceAlbedo - 0.33, 4)
            return 3.5f + 100.0f * Mathf.Pow(SurfaceAlbedo - 0.33f, 4.0f);
        }

        public static Vector3 GetSearchLightDiffuseScalingFactor(Color SurfaceAlbedo)
        {
            return new Vector3(
                GetSearchLightDiffuseScalingFactor(SurfaceAlbedo.r),
                GetSearchLightDiffuseScalingFactor(SurfaceAlbedo.g),
                GetSearchLightDiffuseScalingFactor(SurfaceAlbedo.b)
            );
        }

        /// <summary>
        /// 从 MFP (Mean Free Path) 转换到 DMFP (Diffuse Mean Free Path)
        /// UE5: SubsurfaceProfile. cpp 第497行
        /// DifffuseMeanFreePathInMm = GetDiffuseMeanFreePathFromMeanFreePath(... ) * CmToMm / Dmfp2MfpMagicNumber
        /// </summary>
        public static Color GetDiffuseMeanFreePathFromMeanFreePath(Color SurfaceAlbedo, Color MeanFreePath)
        {
            Vector3 s_search = GetSearchLightDiffuseScalingFactor(SurfaceAlbedo);
            Vector3 s_perp = GetPerpendicularScalingFactor(SurfaceAlbedo);

            return new Color(
                MeanFreePath.r * (s_search.x / s_perp.x),
                MeanFreePath.g * (s_search.y / s_perp.y),
                MeanFreePath.b * (s_search.z / s_perp.z),
                1.0f
            );
        }

        /// <summary>
        /// 从 DMFP 转换到 MFP
        /// </summary>
        public static Color GetMeanFreePathFromDiffuseMeanFreePath(Color SurfaceAlbedo, Color DiffuseMeanFreePath)
        {
            Vector3 s_search = GetSearchLightDiffuseScalingFactor(SurfaceAlbedo);
            Vector3 s_perp = GetPerpendicularScalingFactor(SurfaceAlbedo);

            return new Color(
                DiffuseMeanFreePath.r * (s_perp.x / s_search. x),
                DiffuseMeanFreePath.g * (s_perp.y / s_search.y),
                DiffuseMeanFreePath.b * (s_perp.z / s_search.z),
                1.0f
            );
        }

        // ==============================================================================
        // Burley Core Functions
        // ==============================================================================

        public static float Burley_ScatteringProfile(float r, float A, float S, float L)
        {
            if (S <= 1e-6f || L <= 1e-6f) return 0.0f;

            float D = 1.0f / S;
            float R = r / L;
            const float Inv8Pi = 1.0f / (8.0f * UE_PI);
            float NegRbyD = -R / D;
            float expTerm = Mathf.Exp(NegRbyD) + Mathf.Exp(NegRbyD / 3.0f);
            return A * Mathf.Max(expTerm / (D * L) * Inv8Pi, 0.0f);
        }

        public static float Burley_TransmissionProfile(float r, float A, float S, float L)
        {
            if (L <= 1e-6f) return 0.0f;
            // 0.25 * A * (exp(-S * r/L) + 3 * exp(-S * r / (3*L)))
            float term1 = Mathf.Exp(-S * r / L);
            float term2 = 3.0f * Mathf.Exp(-S * r / (3.0f * L));
            return 0.25f * A * (term1 + term2);
        }

        public static Vector3 Burley_ScatteringProfile(float Radius, Color Albedo, Vector3 S, Color DMFP)
        {
            return new Vector3(
                Burley_ScatteringProfile(Radius, Albedo.r, S.x, DMFP.r),
                Burley_ScatteringProfile(Radius, Albedo.g, S.y, DMFP.g),
                Burley_ScatteringProfile(Radius, Albedo.b, S.z, DMFP.b)
            );
        }

        public static Color Burley_TransmissionProfile(float Radius, Color Albedo, Vector3 S, Color DMFP)
        {
            return new Color(
                Burley_TransmissionProfile(Radius, Albedo.r, S.x, DMFP.r),
                Burley_TransmissionProfile(Radius, Albedo.g, S.y, DMFP.g),
                Burley_TransmissionProfile(Radius, Albedo.b, S.z, DMFP.b),
                1.0f
            );
        }

        // ==============================================================================
        // Generator Functions
        // ==============================================================================

        /// <summary>
        /// 计算 Burley SSS Kernel
        /// 完全匹配 UE5 BurleyNormalizedSSS. cpp:  ComputeMirroredBSSSKernel
        /// </summary>
        /// <param name="TargetBuffer">输出缓冲区</param>
        /// <param name="TargetBufferSize">缓冲区大小 (单边采样数，包含中心)</param>
        /// <param name="SurfaceAlbedo">表面反照率</param>
        /// <param name="DiffuseMeanFreePath">漫反射平均自由程 (已经是mm单位)</param>
        /// <param name="ScatterRadius">散射半径 (cm)</param>
        public static void ComputeMirroredBSSSKernel(Color[] TargetBuffer, int TargetBufferSize,
            Color SurfaceAlbedo, Color DiffuseMeanFreePath, float ScatterRadius)
        {
            if (TargetBufferSize <= 0) return;

            int nNonMirroredSamples = TargetBufferSize;
            // 总采样数 = 单边 * 2 - 1
            int nTotalSamples = nNonMirroredSamples * 2 - 1;

            // 限制最大采样数，防止数组越界 (UE5 限制是 64)
            if (nTotalSamples >= 64) nTotalSamples = 63;

            Vector3 ScalingFactor = GetSearchLightDiffuseScalingFactor(SurfaceAlbedo);
            Color[] kernel = new Color[64];

            // Range 根据采样数选择
            float Range = (nTotalSamples > 20) ? 3.0f : 2.0f;
            const float Exponent = 2.0f;

            // 1. Calculate the offsets (存入 Alpha)
            float step = 2.0f * Range / (nTotalSamples - 1);
            for (int i = 0; i < nTotalSamples; i++)
            {
                float o = -Range + (float)i * step;
                float sign = o < 0.0f ? -1.0f : 1.0f;
                float val = Range * sign * Mathf.Abs(Mathf.Pow(o, Exponent)) / Mathf.Pow(Range, Exponent);
                kernel[i] = new Color(0, 0, 0, val);
            }
            // 强制中心为0
            kernel[nTotalSamples / 2] = new Color(kernel[nTotalSamples / 2].r, kernel[nTotalSamples / 2].g, kernel[nTotalSamples / 2].b, 0.0f);

            // 2. Calculate the weights
            // UE5: SpaceScale = ScatterRadius * 10.0f (cm to mm)
            float SpaceScale = ScatterRadius * CmToMm;

            for (int i = 0; i < nTotalSamples; i++)
            {
                float w0 = i > 0 ?  Mathf.Abs(kernel[i].a - kernel[i - 1].a) : 0.0f;
                float w1 = i < nTotalSamples - 1 ? Mathf. Abs(kernel[i].a - kernel[i + 1].a) : 0.0f;
                float area = (w0 + w1) / 2.0f;

                float r = Mathf.Abs(kernel[i].a) * SpaceScale;

                Vector3 t = area * Burley_ScatteringProfile(r, SurfaceAlbedo, ScalingFactor, DiffuseMeanFreePath);

                kernel[i] = new Color(t.x, t.y, t.z, kernel[i].a);
            }

            // 3. Tweak:  multiply offset by 2.0
            for (int i = 0; i < nTotalSamples; i++)
            {
                kernel[i] = new Color(kernel[i].r, kernel[i].g, kernel[i].b, kernel[i].a * 2.0f);
            }

            // 4. 重排序：中心点移到 [0]
            Color centerPixel = kernel[nTotalSamples / 2];
            for (int i = nTotalSamples / 2; i > 0; i--)
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
                float nr = sum.x > 0 ? kernel[i].r / sum.x : kernel[i].r;
                float ng = sum.y > 0 ? kernel[i].g / sum.y : kernel[i]. g;
                float nb = sum.z > 0 ? kernel[i].b / sum.z : kernel[i].b;
                kernel[i] = new Color(nr, ng, nb, kernel[i].a);
            }

            // 6. 输出 (center + positive samples)
            // UE5: TargetBuffer[0] = kernel[0]; // center
            //      TargetBuffer[i+1] = kernel[nNonMirroredSamples + i]; // positive samples
            TargetBuffer[0] = kernel[0];
            for (int i = 0; i < nNonMirroredSamples - 1; i++)
            {
                TargetBuffer[i + 1] = kernel[nNonMirroredSamples + i];
            }
        }

        /// <summary>
        /// 计算 Burley 透射 Profile
        /// 完全匹配 UE5 BurleyNormalizedSSS. cpp: ComputeTransmissionProfileBurley
        /// </summary>
        /// <param name="TargetBuffer">输出缓冲区</param>
        /// <param name="TargetBufferSize">缓冲区大小</param>
        /// <param name="ExtinctionScale">消光系数</param>
        /// <param name="SurfaceAlbedo">表面反照率</param>
        /// <param name="DiffuseMeanFreePathInMm">漫反射平均自由程 (mm)</param>
        /// <param name="WorldUnitScale">世界单位缩放</param>
        /// <param name="TransmissionTintColor">透射染色</param>
        public static void ComputeTransmissionProfileBurley(
            Color[] TargetBuffer, int TargetBufferSize, float ExtinctionScale,
            Color SurfaceAlbedo, Color DiffuseMeanFreePathInMm,
            float WorldUnitScale, Color TransmissionTintColor)
        {
            // UE5 单位缩放逻辑
            const float SubsurfaceScatteringUnitInCm = 0.1f;
            float UnitScale = WorldUnitScale / SubsurfaceScatteringUnitInCm;
            float InvUnitScale = 1.0f / UnitScale;

            // Legacy 模式 (UE5 默认开启)
            // CVarSSProfilesTransmissionUseLegacy 默认值为 1
            InvUnitScale *= 0.1f;

            const float MaxTransmissionProfileDistance = 5.0f; // 5cm base
            
            Vector3 ScalingFactor = GetSearchLightDiffuseScalingFactor(SurfaceAlbedo);

            float InvSize = 1.0f / TargetBufferSize;

            for (int i = 0; i < TargetBufferSize; ++i)
            {
                float DistanceInMm = i * InvSize * (MaxTransmissionProfileDistance * CmToMm) * InvUnitScale;
                float OffsetInMm = (ProfileRadiusOffset * CmToMm) * InvUnitScale;

                // 计算透射颜色
                Color TransmissionProfile = Burley_TransmissionProfile(DistanceInMm + OffsetInMm, SurfaceAlbedo, ScalingFactor, DiffuseMeanFreePathInMm);

                Color finalColor = TransmissionProfile * TransmissionTintColor;

                // Alpha 通道存储阴影衰减 (Extinction)
                finalColor.a = Mathf.Exp(-DistanceInMm * ExtinctionScale);

                TargetBuffer[i] = finalColor;
            }

            // 强制最后一个像素为黑 (确保 Fade out)
            if (TargetBufferSize > 0)
            {
                TargetBuffer[TargetBufferSize - 1] = Color.black;
            }
        }
    }
}