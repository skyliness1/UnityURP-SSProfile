#if UNITY_EDITOR
using System.Collections.Generic;
using UnityEditor;
using UnityEngine;
using System. IO;

namespace SoulRender
{
    public class SSProfileTextureGenerator
    {
        private const string TextureSavePath = "Assets/Scripts/Soul/Rendering/Enviroment/SSProfile/GlobalTextures";
        private const string TextureFileName = "SSProfile_Packed_LUT";

        private const int TEXTURE_WIDTH = 128;
        private const int MAX_PROFILE_COUNT = 256;

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

        private const float ENC_WORLDUNITSCALE_IN_CM_TO_UNIT = 0.02f;
        private const float ENC_DIFFUSEMEANFREEPATH_IN_MM_TO_UNIT = 0.0002f;
        private const float ENC_EXTINCTIONSCALE_FACTOR = 0.01f;
        private const float SSSS_MAX_DUAL_SPECULAR_ROUGHNESS = 2.0f;
        
        private const float SUBSURFACE_RADIUS_SCALE = 1024.0f;
        private const float SUBSURFACE_KERNEL_SIZE = 3.0f;

        private const float Dmfp2MfpMagicNumber = 0.6f;
        private const float CmToMm = 10.0f;
        private const float MmToCm = 0.1f;
        
        private const float TABLE_MAX_RGB = 1.0f;
        private const float TABLE_MAX_A = 3.0f;

        private static float EncodeWorldUnitScale(float WorldUnitScale)
        {
            return Mathf.Clamp01(WorldUnitScale * ENC_WORLDUNITSCALE_IN_CM_TO_UNIT);
        }

        private static Color EncodeDiffuseMeanFreePath(Color DiffuseMeanFreePath)
        {
            // 确保 Clamp 到 [0, 500mm]
            return new Color(
                Mathf.Clamp01(DiffuseMeanFreePath.r * ENC_DIFFUSEMEANFREEPATH_IN_MM_TO_UNIT),
                Mathf.Clamp01(DiffuseMeanFreePath.g * ENC_DIFFUSEMEANFREEPATH_IN_MM_TO_UNIT),
                Mathf.Clamp01(DiffuseMeanFreePath.b * ENC_DIFFUSEMEANFREEPATH_IN_MM_TO_UNIT),
                Mathf.Clamp01(DiffuseMeanFreePath.a * ENC_DIFFUSEMEANFREEPATH_IN_MM_TO_UNIT)
            );
        }

        private static float EncodeScatteringDistribution(float ScatteringDistribution)
        {
            return Mathf.Clamp01((ScatteringDistribution + 1.0f) * 0.5f);
        }

        private static float EncodeExtinctionScale(float ExtinctionScale)
        {
            return Mathf.Clamp01(ExtinctionScale * ENC_EXTINCTIONSCALE_FACTOR);
        }

        private static void SetupSurfaceAlbedoAndDiffuseMeanFreePath(ref Color SurfaceAlbedo, ref Color Dmfp)
        {
            Color MFP = BurleyNormalizedSSS.GetMeanFreePathFromDiffuseMeanFreePath(SurfaceAlbedo, Dmfp);

            float maxComp = Mathf.Max(MFP.r, Mathf.Max(MFP.g, MFP.b));
            int indexOfMaxComp = (MFP.r == maxComp) ? 0 : ((MFP.g == maxComp) ? 1 : 2);

            SurfaceAlbedo.a = (indexOfMaxComp == 0) ? SurfaceAlbedo.r : 
                              ((indexOfMaxComp == 1) ? SurfaceAlbedo.g : SurfaceAlbedo.b);
            Dmfp.a = (indexOfMaxComp == 0) ? Dmfp.r :  
                     ((indexOfMaxComp == 1) ? Dmfp.g : Dmfp.b);
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

            Texture2D texture = new Texture2D(TEXTURE_WIDTH, MAX_PROFILE_COUNT, TextureFormat.RGBAHalf, false, true);
            texture.name = TextureFileName;
            texture.wrapMode = TextureWrapMode.Clamp;
            texture.filterMode = FilterMode.Point;
            texture.anisoLevel = 0;

            Color[] pixels = new Color[TEXTURE_WIDTH * MAX_PROFILE_COUNT];
            for (int i = 0; i < pixels.Length; i++)
            {
                pixels[i] = Color.clear;
            }
            
            var profiles = manager.GetAllProfilesForTextureGeneration();
            Debug.Log($"[SSProfileTextureGenerator] Processing{profiles.Count} profiles");

            foreach (var profile in profiles)
            {
                if (profile == null)
                {
                    continue;
                }
                else
                {
                    SSProfileUpgrader.ValidateAndFix(profile);
                }

                int row = profile.ProfileId;
                if (row < 0 || row >= MAX_PROFILE_COUNT) 
                {
                    Debug.LogWarning($"[SSProfileTextureGenerator] Invalid profile ID: {row} for {profile.name}");
                    continue;
                }

                Debug.Log($"[SSProfileTextureGenerator] Processing profile: {profile.name} (ID:{row})");

                int rowStart = row * TEXTURE_WIDTH;
                
                const float Bias = 0.009f;

                Color surfaceAlbedo = ClampColor(profile.surfaceAlbedo, Bias, 1.0f);
                Color meanFreePathColor = ClampColor(profile.meanFreePathColor, Bias, 1.0f);
                Color transmissionTintColor = ClampColor(profile.transmissionTintColor, Bias, 1.0f);
                Color tint = ClampColor(profile.tint, 0.0f, 1.0f);
                Color boundaryColorBleed = ClampColor(profile.boundaryColorBleed, 0.0f, 1.0f);

                // ============================================================
                // DMFP 计算
                // ============================================================
                
                Color meanFreePathInCm = new Color(
                    meanFreePathColor.r * profile.meanFreePathDistance,
                    meanFreePathColor.g * profile.meanFreePathDistance,
                    meanFreePathColor.b * profile.meanFreePathDistance,
                    1.0f
                );
                
                Color diffuseMeanFreePathInMm = BurleyNormalizedSSS. GetDiffuseMeanFreePathFromMeanFreePath(
                    surfaceAlbedo, meanFreePathInCm);
                
                Debug.Log($"[LUT Gen] Profile {row}:  DMFP before scaling = R={diffuseMeanFreePathInMm.r:F4}, G={diffuseMeanFreePathInMm.g:F4}, B={diffuseMeanFreePathInMm.b:F4}");
                
                diffuseMeanFreePathInMm = new Color(
                    diffuseMeanFreePathInMm.r * CmToMm,
                    diffuseMeanFreePathInMm.g * CmToMm,
                    diffuseMeanFreePathInMm.b * CmToMm,
                    1.0f
                );
                
                Debug.Log($"[LUT Gen] Profile {row}: DMFP after scaling = R={diffuseMeanFreePathInMm.r:F4}, G={diffuseMeanFreePathInMm.g:F4}, B={diffuseMeanFreePathInMm.b:F4}");

                Color surfaceAlbedoForTexture = surfaceAlbedo;
                Color dmfpForTexture = diffuseMeanFreePathInMm;
                SetupSurfaceAlbedoAndDiffuseMeanFreePath(ref surfaceAlbedoForTexture, ref dmfpForTexture);
                
                Debug.Log($"[LUT Gen] Profile {row}:  DMFP final (after Setup) = R={dmfpForTexture.r:F4}, G={dmfpForTexture.g:F4}, B={dmfpForTexture.b:F4}, A={dmfpForTexture.a:F4}");

                // ============================================================
                // 写入纹理数据
                // ============================================================
                
                Color tintScale = tint;
                tintScale.a = EncodeWorldUnitScale(profile.worldUnitScale);
                pixels[rowStart + SSSS_TINT_SCALE_OFFSET] = tintScale;

                pixels[rowStart + BSSS_SURFACEALBEDO_OFFSET] = surfaceAlbedoForTexture;
                
                pixels[rowStart + BSSS_DMFP_OFFSET] = EncodeDiffuseMeanFreePath(dmfpForTexture);

                Color transmissionParams = new Color(
                    EncodeExtinctionScale(profile.extinctionScale),
                    profile.normalScale,
                    EncodeScatteringDistribution(profile.scatteringDistribution),
                    1.0f / profile.IOR
                );
                pixels[rowStart + SSSS_TRANSMISSION_OFFSET] = transmissionParams;

                Color boundaryBleed = boundaryColorBleed;
                boundaryBleed.a = 0.0f;
                pixels[rowStart + SSSS_BOUNDARY_COLOR_BLEED_OFFSET] = boundaryBleed;

                float materialRoughnessToAverage = profile.roughness0 * (1.0f - profile.lobeMix) + 
                                                   profile.roughness1 * profile.lobeMix;
                Color dualSpecular = new Color(
                    Mathf.Clamp01(profile.roughness0 / SSSS_MAX_DUAL_SPECULAR_ROUGHNESS),
                    Mathf.Clamp01(profile.roughness1 / SSSS_MAX_DUAL_SPECULAR_ROUGHNESS),
                    profile.lobeMix,
                    Mathf.Clamp01(materialRoughnessToAverage / SSSS_MAX_DUAL_SPECULAR_ROUGHNESS)
                );
                pixels[rowStart + SSSS_DUAL_SPECULAR_OFFSET] = dualSpecular;

                // ============================================================
                // Kernel 生成
                // ============================================================
                
                float scatterRadius = Mathf.Max(
                    Mathf.Max(diffuseMeanFreePathInMm.r, Mathf.Max(diffuseMeanFreePathInMm.g, diffuseMeanFreePathInMm.b)) * MmToCm,
                    0.1f
                );

                Color[] kernel0 = new Color[SSSS_KERNEL0_SIZE];
                BurleyNormalizedSSS.ComputeMirroredBSSSKernel(kernel0, SSSS_KERNEL0_SIZE,
                    surfaceAlbedo, diffuseMeanFreePathInMm, scatterRadius);
                
                Color[] kernel1 = new Color[SSSS_KERNEL1_SIZE];
                BurleyNormalizedSSS.ComputeMirroredBSSSKernel(kernel1, SSSS_KERNEL1_SIZE,
                    surfaceAlbedo, diffuseMeanFreePathInMm, scatterRadius);
                
                Color[] kernel2 = new Color[SSSS_KERNEL2_SIZE];
                BurleyNormalizedSSS.ComputeMirroredBSSSKernel(kernel2, SSSS_KERNEL2_SIZE,
                    surfaceAlbedo, diffuseMeanFreePathInMm, scatterRadius);
                
                float worldScaledScatterRadius = scatterRadius * profile.worldUnitScale * CmToMm;
                
                float scatterRadiusInCm = Mathf.Max(
                    Mathf.Max(diffuseMeanFreePathInMm.r, Mathf.Max(diffuseMeanFreePathInMm.g, diffuseMeanFreePathInMm.b)) * MmToCm,
                    0.1f
                );

                WriteKernelData(pixels, rowStart + SSSS_KERNEL0_OFFSET, kernel0, SSSS_KERNEL0_SIZE, scatterRadiusInCm);
                WriteKernelData(pixels, rowStart + SSSS_KERNEL1_OFFSET, kernel1, SSSS_KERNEL1_SIZE, scatterRadiusInCm);
                WriteKernelData(pixels, rowStart + SSSS_KERNEL2_OFFSET, kernel2, SSSS_KERNEL2_SIZE, scatterRadiusInCm);
                
                
                // ============================================================
                // Transmission Profile
                // ============================================================
                Color[] transData = new Color[BSSS_TRANSMISSION_PROFILE_SIZE];
                BurleyNormalizedSSS.ComputeTransmissionProfileBurley(
                    transData, BSSS_TRANSMISSION_PROFILE_SIZE,
                    profile.extinctionScale, surfaceAlbedo,
                    diffuseMeanFreePathInMm,
                    profile.worldUnitScale, transmissionTintColor, false);

                for (int t = 0; t < BSSS_TRANSMISSION_PROFILE_SIZE; t++)
                {
                    pixels[rowStart + BSSS_TRANSMISSION_PROFILE_OFFSET + t] = transData[t];
                }
            }

            texture.SetPixels(pixels);
            texture.Apply();

            byte[] exrData = texture.EncodeToEXR(Texture2D.EXRFlags.OutputAsFloat);
            
            if (File.Exists(exrPath))
            {
                FileInfo fi = new FileInfo(exrPath);
                if (fi.IsReadOnly)
                {
                    fi.IsReadOnly = false;
                }
            }
            
            File.WriteAllBytes(exrPath, exrData);
            Debug.Log($"[SSProfileTextureGenerator] Wrote {exrData.Length} bytes to {exrPath}");
            
            Object.DestroyImmediate(texture);
            
            AssetDatabase.Refresh();
            AssetDatabase.ImportAsset(exrPath, ImportAssetOptions.ForceUpdate);
            
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
        /// UE5:  C.a = (C.a / TABLE_MAX_A) * (ScatterRadius / SUBSURFACE_RADIUS_SCALE)
        /// </summary>
        private static void WriteKernelData(Color[] pixels, int startOffset, Color[] kernelData, int kernelSize, float scatterRadius)
        {
            for (int k = 0; k < kernelSize; k++)
            {
                Color c = kernelData[k];
                
                c.a /= TABLE_MAX_A;

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
