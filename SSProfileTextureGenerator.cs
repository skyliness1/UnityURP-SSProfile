#if UNITY_EDITOR
using System.Collections.Generic;
using UnityEditor;
using UnityEngine;
using System.IO;

namespace SoulRender
{
    public class SSProfileTextureGenerator
    {
        private const string TextureSavePath = "Assets/Scripts/Soul/Rendering/Enviroment/SSProfile/GlobalTextures";
        private const string TextureFileName = "SSProfile_Packed_LUT";

        private const int TEXTURE_WIDTH = 128;
        private const int MAX_PROFILE_COUNT = 256;

        // UE5 偏移量定义 (与 SubsurfaceProfileCommon. ush 一致)
        private const int SSSS_TINT_SCALE_OFFSET = 0;
        private const int BSSS_SURFACEALBEDO_OFFSET = 1;
        private const int BSSS_DMFP_OFFSET = 2;
        private const int SSSS_TRANSMISSION_OFFSET = 3;
        private const int SSSS_BOUNDARY_COLOR_BLEED_OFFSET = 4;
        private const int SSSS_DUAL_SPECULAR_OFFSET = 5;
        private const int SSSS_KERNEL0_OFFSET = 6;
        private const int SSSS_KERNEL0_SIZE = 13;
        private const int SSSS_KERNEL1_OFFSET = 19;
        private const int SSSS_KERNEL1_SIZE = 9;
        private const int SSSS_KERNEL2_OFFSET = 28;
        private const int SSSS_KERNEL2_SIZE = 6;
        private const int BSSS_TRANSMISSION_PROFILE_OFFSET = 34;
        private const int BSSS_TRANSMISSION_PROFILE_SIZE = 32;

        // 编码常量 (与 SubsurfaceProfileCommon.ush 一致)
        private const float ENC_WORLDUNITSCALE_IN_CM_TO_UNIT = 0.02f;
        private const float ENC_DIFFUSEMEANFREEPATH_IN_MM_TO_UNIT = 0.01f * 0.2f;
        private const float ENC_EXTINCTIONSCALE_FACTOR = 0.01f;
        private const float SSSS_MAX_DUAL_SPECULAR_ROUGHNESS = 2.0f;
        
        // UE5: SUBSURFACE_RADIUS_SCALE = 1024 (定义在 SubsurfaceProfile.h)
        private const float SUBSURFACE_RADIUS_SCALE = 1024.0f;
        
        // UE5: SUBSURFACE_KERNEL_SIZE = 3 (定义在 SubsurfaceProfile.h)
        private const float SUBSURFACE_KERNEL_SIZE = 3.0f;

        // UE5 魔法数字
        private const float Dmfp2MfpMagicNumber = 0.6f;
        private const float CmToMm = 10.0f;
        private const float MmToCm = 0.1f;
        
        // UE5: TABLE_MAX_RGB = 1.0, TABLE_MAX_A = SUBSURFACE_KERNEL_SIZE = 3.0
        private const float TABLE_MAX_RGB = 1.0f;
        private const float TABLE_MAX_A = SUBSURFACE_KERNEL_SIZE; // 3.0

        private static float EncodeWorldUnitScale(float WorldUnitScale)
        {
            return Mathf.Clamp01(WorldUnitScale * ENC_WORLDUNITSCALE_IN_CM_TO_UNIT);
        }

        private static Color EncodeDiffuseMeanFreePath(Color DiffuseMeanFreePath)
        {
            return new Color(
                Mathf. Clamp01(DiffuseMeanFreePath.r * ENC_DIFFUSEMEANFREEPATH_IN_MM_TO_UNIT),
                Mathf.Clamp01(DiffuseMeanFreePath.g * ENC_DIFFUSEMEANFREEPATH_IN_MM_TO_UNIT),
                Mathf.Clamp01(DiffuseMeanFreePath.b * ENC_DIFFUSEMEANFREEPATH_IN_MM_TO_UNIT),
                Mathf.Clamp01(DiffuseMeanFreePath.a * ENC_DIFFUSEMEANFREEPATH_IN_MM_TO_UNIT)
            );
        }

        private static float EncodeScatteringDistribution(float ScatteringDistribution)
        {
            // UE5: (ScatteringDistribution + 1.0) * 0.5
            // ScatteringDistribution 范围是 [-1, 1]，编码后是 [0, 1]
            return Mathf.Clamp01((ScatteringDistribution + 1.0f) * 0.5f);
        }

        private static float EncodeExtinctionScale(float ExtinctionScale)
        {
            return Mathf.Clamp01(ExtinctionScale * ENC_EXTINCTIONSCALE_FACTOR);
        }

        /// <summary>
        /// UE5: SetupSurfa【ceAlbedoAndDiffuseMeanFreePath
        /// 设置 SurfaceAlbedo. a 和 DMFP.a 为最大通道对应的值
        /// </summary>
        private static void SetupSurfaceAlbedoAndDiffuseMeanFreePath(ref Color SurfaceAlbedo, ref Color Dmfp)
        {
            // 从 DMFP 计算 MFP
            Color MFP = BurleyNormalizedSSS.GetMeanFreePathFromDiffuseMeanFreePath(SurfaceAlbedo, Dmfp);

            // 找到最大通道
            float maxComp = Mathf.Max(MFP.r, Mathf.Max(MFP.g, MFP.b));
            int indexOfMaxComp = (MFP.r == maxComp) ? 0 : ((MFP.g == maxComp) ? 1 : 2);

            // 存储最大通道对应的 Albedo 和 DMFP 值到 Alpha
            SurfaceAlbedo.a = (indexOfMaxComp == 0) ? SurfaceAlbedo.r : 
                              ((indexOfMaxComp == 1) ? SurfaceAlbedo.g : SurfaceAlbedo.b);
            Dmfp.a = (indexOfMaxComp == 0) ? Dmfp.r : 
                     ((indexOfMaxComp == 1) ? Dmfp.g : Dmfp.b);

            // Clamp DMFP 到编码范围
            float maxDmfpValue = 1.0f / ENC_DIFFUSEMEANFREEPATH_IN_MM_TO_UNIT;
            Dmfp.r = Mathf.Clamp(Dmfp.r, 0.0f, maxDmfpValue);
            Dmfp.g = Mathf.Clamp(Dmfp.g, 0.0f, maxDmfpValue);
            Dmfp.b = Mathf.Clamp(Dmfp.b, 0.0f, maxDmfpValue);
            Dmfp.a = Mathf.Clamp(Dmfp.a, 0.0f, maxDmfpValue);
        }

        public static void UpdatePackedTexture(SSProfileManager manager, ref Texture2D textureRef)
        {
            Debug.Log($"[SSProfileTextureGenerator] Starting texture generation.. .");
            
            if (!Directory.Exists(TextureSavePath))
            {
                Directory.CreateDirectory(TextureSavePath);
                AssetDatabase.Refresh();
            }
            
            string exrPath = $"{TextureSavePath}/{TextureFileName}.exr";

            // 创建临时纹理 (Linear, Half precision)
            Texture2D texture = new Texture2D(TEXTURE_WIDTH, MAX_PROFILE_COUNT, TextureFormat.RGBAHalf, false, true);
            texture.name = TextureFileName;
            texture.wrapMode = TextureWrapMode.Clamp;
            texture.filterMode = FilterMode.Point;
            texture.anisoLevel = 0;

            // 初始化所有像素为透明黑
            Color[] pixels = new Color[TEXTURE_WIDTH * MAX_PROFILE_COUNT];
            for (int i = 0; i < pixels.Length; i++)
            {
                pixels[i] = Color.clear;
            }
            
            var profiles = manager.GetAllProfilesForTextureGeneration();
            Debug.Log($"[SSProfileTextureGenerator] Processing {profiles.Count} profiles");

            foreach (var profile in profiles)
            {
                if (profile == null)
                {
                    continue;
                }

                int row = profile.ProfileId;
                if (row < 0 || row >= MAX_PROFILE_COUNT) 
                {
                    Debug.LogWarning($"[SSProfileTextureGenerator] Invalid profile ID: {row} for {profile.name}");
                    continue;
                }

                Debug.Log($"[SSProfileTextureGenerator] Processing profile: {profile.name} (ID:{row})");

                int rowStart = row * TEXTURE_WIDTH;
                
                // UE5: Bias = 0.009f 用于防止除零
                const float Bias = 0.009f;

                // Clamp 输入颜色
                Color surfaceAlbedo = ClampColor(profile.surfaceAlbedo, Bias, 1.0f);
                Color meanFreePathColor = ClampColor(profile.meanFreePathColor, Bias, 1.0f);
                Color transmissionTintColor = ClampColor(profile.transmissionTintColor, Bias, 1.0f);
                Color tint = ClampColor(profile.tint, 0.0f, 1.0f);
                Color boundaryColorBleed = ClampColor(profile.boundaryColorBleed, 0.0f, 1.0f);

                // ============================================================
                // UE5 DMFP 计算流程 (SubsurfaceProfile.cpp 第485-510行)
                // ============================================================
                
                // 1. MeanFreePath (用户输入，单位 cm)
                Color meanFreePathInCm = new Color(
                    meanFreePathColor.r * profile.meanFreePathDistance,
                    meanFreePathColor.g * profile.meanFreePathDistance,
                    meanFreePathColor.b * profile.meanFreePathDistance,
                    1.0f
                );
                
                // 2. 转换为 DMFP (单位 mm)
                // UE5: DiffuseMeanFreePathInMm = GetDiffuseMeanFreePathFromMeanFreePath(... ) * CmToMm / Dmfp2MfpMagicNumber
                Color diffuseMeanFreePathInMm = BurleyNormalizedSSS.GetDiffuseMeanFreePathFromMeanFreePath(
                    surfaceAlbedo, meanFreePathInCm);
                diffuseMeanFreePathInMm = new Color(
                    diffuseMeanFreePathInMm.r * CmToMm / Dmfp2MfpMagicNumber,
                    diffuseMeanFreePathInMm.g * CmToMm / Dmfp2MfpMagicNumber,
                    diffuseMeanFreePathInMm.b * CmToMm / Dmfp2MfpMagicNumber,
                    1.0f
                );

                // 3. 准备纹理存储的值
                Color surfaceAlbedoForTexture = surfaceAlbedo;
                Color dmfpForTexture = diffuseMeanFreePathInMm;
                SetupSurfaceAlbedoAndDiffuseMeanFreePath(ref surfaceAlbedoForTexture, ref dmfpForTexture);

                // ============================================================
                // 写入纹理数据
                // ============================================================
                
                // [0] Tint + WorldUnitScale
                Color tintScale = tint;
                tintScale.a = EncodeWorldUnitScale(profile.worldUnitScale);
                pixels[rowStart + SSSS_TINT_SCALE_OFFSET] = tintScale;

                // [1] Surface Albedo
                pixels[rowStart + BSSS_SURFACEALBEDO_OFFSET] = surfaceAlbedoForTexture;
                
                // [2] DMFP (编码后)
                pixels[rowStart + BSSS_DMFP_OFFSET] = EncodeDiffuseMeanFreePath(dmfpForTexture);

                // [3] Transmission 参数
                Color transmissionParams = new Color(
                    EncodeExtinctionScale(profile.extinctionScale),
                    profile.normalScale,
                    EncodeScatteringDistribution(profile.scatteringDistribution),
                    1.0f / profile.IOR
                );
                pixels[rowStart + SSSS_TRANSMISSION_OFFSET] = transmissionParams;

                // [4] Boundary Color Bleed + SSS Type
                // UE5: Alpha 通道存储 SSS Type (0 = Burley, 1 = Separable)
                Color boundaryBleed = boundaryColorBleed;
                boundaryBleed.a = 0.0f; // Burley type
                pixels[rowStart + SSSS_BOUNDARY_COLOR_BLEED_OFFSET] = boundaryBleed;

                // [5] Dual Specular
                float materialRoughnessToAverage = profile.roughness0 * (1.0f - profile.lobeMix) + 
                                                   profile.roughness1 * profile.lobeMix;
                Color dualSpecular = new Color(
                    Mathf.Clamp01(profile.roughness0 / SSSS_MAX_DUAL_SPECULAR_ROUGHNESS),
                    Mathf. Clamp01(profile.roughness1 / SSSS_MAX_DUAL_SPECULAR_ROUGHNESS),
                    profile.lobeMix,
                    Mathf.Clamp01(materialRoughnessToAverage / SSSS_MAX_DUAL_SPECULAR_ROUGHNESS)
                );
                pixels[rowStart + SSSS_DUAL_SPECULAR_OFFSET] = dualSpecular;

                // ============================================================
                // Kernel 生成
                // UE5: SubsurfaceProfile.cpp 第520-580行
                // ============================================================
                
                // ScatterRadius = max(DMFP) * MmToCm (转回 cm)
                float scatterRadius = Mathf.Max(
                    Mathf.Max(diffuseMeanFreePathInMm.r, Mathf.Max(diffuseMeanFreePathInMm. g, diffuseMeanFreePathInMm.b)) * MmToCm,
                    0.1f
                );

                // 生成三个质量等级的 Kernel
                Color[] kernel0 = new Color[SSSS_KERNEL0_SIZE];
                BurleyNormalizedSSS.ComputeMirroredBSSSKernel(kernel0, SSSS_KERNEL0_SIZE,
                    surfaceAlbedo, diffuseMeanFreePathInMm, scatterRadius);
                
                Color[] kernel1 = new Color[SSSS_KERNEL1_SIZE];
                BurleyNormalizedSSS.ComputeMirroredBSSSKernel(kernel1, SSSS_KERNEL1_SIZE,
                    surfaceAlbedo, diffuseMeanFreePathInMm, scatterRadius);
                
                Color[] kernel2 = new Color[SSSS_KERNEL2_SIZE];
                BurleyNormalizedSSS.ComputeMirroredBSSSKernel(kernel2, SSSS_KERNEL2_SIZE,
                    surfaceAlbedo, diffuseMeanFreePathInMm, scatterRadius);

                // ============================================================
                // Kernel 编码
                // UE5: SubsurfaceProfile.cpp 第570-590行
                // 
                // 关键公式: 
                // C. rgb /= TableMaxRGB (= 1.0)
                // C.a /= TableMaxA (= 3.0)
                // C.a *= ScatterRadius / SUBSURFACE_RADIUS_SCALE
                // 
                // 其中 ScatterRadius 已经包含了 WorldUnitScale
                // ============================================================
                
                // UE5: ScatterRadius 需要乘以 WorldUnitScale (转为世界单位)
                // 然后再乘以 CmToMm 转为 mm
                float worldScaledScatterRadius = scatterRadius * profile.worldUnitScale * CmToMm;

                WriteKernelData(pixels, rowStart + SSSS_KERNEL0_OFFSET, kernel0, SSSS_KERNEL0_SIZE, worldScaledScatterRadius);
                WriteKernelData(pixels, rowStart + SSSS_KERNEL1_OFFSET, kernel1, SSSS_KERNEL1_SIZE, worldScaledScatterRadius);
                WriteKernelData(pixels, rowStart + SSSS_KERNEL2_OFFSET, kernel2, SSSS_KERNEL2_SIZE, worldScaledScatterRadius);

                // ============================================================
                // Transmission Profile
                // ============================================================
                Color[] transData = new Color[BSSS_TRANSMISSION_PROFILE_SIZE];
                BurleyNormalizedSSS.ComputeTransmissionProfileBurley(
                    transData, BSSS_TRANSMISSION_PROFILE_SIZE,
                    profile.extinctionScale, surfaceAlbedo,
                    diffuseMeanFreePathInMm,
                    profile.worldUnitScale, transmissionTintColor
                );

                for (int t = 0; t < BSSS_TRANSMISSION_PROFILE_SIZE; t++)
                {
                    pixels[rowStart + BSSS_TRANSMISSION_PROFILE_OFFSET + t] = transData[t];
                }
            }

            texture.SetPixels(pixels);
            texture.Apply();

            // 保存为 EXR
            byte[] exrData = texture.EncodeToEXR(Texture2D.EXRFlags.OutputAsFloat);
            
            if (File.Exists(exrPath))
            {
                FileInfo fi = new FileInfo(exrPath);
                if (fi.IsReadOnly) fi.IsReadOnly = false;
            }
            
            File.WriteAllBytes(exrPath, exrData);
            Debug.Log($"[SSProfileTextureGenerator] Wrote {exrData.Length} bytes to {exrPath}");
            
            Object.DestroyImmediate(texture);
            
            AssetDatabase.Refresh();
            AssetDatabase.ImportAsset(exrPath, ImportAssetOptions.ForceUpdate);
            
            // 配置纹理导入设置
            TextureImporter importer = AssetImporter.GetAtPath(exrPath) as TextureImporter;
            if (importer != null)
            {
                importer.textureType = TextureImporterType.Default;
                importer.sRGBTexture = false;
                importer.mipmapEnabled = false;
                importer.filterMode = FilterMode.Point;
                importer.wrapMode = TextureWrapMode.Clamp;
                importer.textureCompression = TextureImporterCompression.Uncompressed;
                importer.npotScale = TextureImporterNPOTScale.None;
                
                TextureImporterPlatformSettings platformSettings = importer.GetDefaultPlatformTextureSettings();
                platformSettings.format = TextureImporterFormat.RGBAHalf;
                platformSettings.overridden = true;
                importer.SetPlatformTextureSettings(platformSettings);
                
                importer.SaveAndReimport();
            }

            textureRef = AssetDatabase.LoadAssetAtPath<Texture2D>(exrPath);
            
            if (textureRef != null)
            {
                Debug.Log($"[SSProfileTextureGenerator] Successfully generated texture: {textureRef.width}x{textureRef.height}");
            }
            else
            {
                Debug.LogError($"[SSProfileTextureGenerator] Failed to load texture from {exrPath}");
            }
        }

        /// <summary>
        /// 写入 Kernel 数据到纹理
        /// 
        /// UE5 编码公式 (SubsurfaceProfile.cpp 第570-590行):
        /// C.rgb /= TableMaxRGB (= 1.0, 所以不变)
        /// C.a /= TableMaxA (= 3.0)
        /// C.a *= ScatterRadius / SUBSURFACE_RADIUS_SCALE
        /// </summary>
        private static void WriteKernelData(Color[] pixels, int startOffset, Color[] kernelData, int kernelSize, float scatterRadius)
        {
            for (int k = 0; k < kernelSize; k++)
            {
                Color c = kernelData[k];

                // RGB:  除以 TABLE_MAX_RGB (= 1.0, 实际不变)
                c.r /= TABLE_MAX_RGB;
                c.g /= TABLE_MAX_RGB;
                c.b /= TABLE_MAX_RGB;

                // Alpha: 除以 TABLE_MAX_A, 然后乘以 ScatterRadius / SUBSURFACE_RADIUS_SCALE
                c.a /= TABLE_MAX_A;
                c.a *= scatterRadius / SUBSURFACE_RADIUS_SCALE;

                pixels[startOffset + k] = c;
            }
        }

        private static Color ClampColor(Color c, float min, float max)
        {
            return new Color(
                Mathf.Clamp(c.r, min, max),
                Mathf.Clamp(c.g, min, max),
                Mathf.Clamp(c.b, min, max),
                Mathf.Clamp(c.a, 0.0f, 1.0f)
            );
        }
    }
}
#endif
