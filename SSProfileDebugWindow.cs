#if UNITY_EDITOR
using UnityEngine;
using UnityEditor;

namespace SoulRender
{
    public class SSProfileDebugWindow : EditorWindow
    {
        private Texture2D _texture;
        private int _profileId = 0;
        private Vector2 _scrollPos;
        
        [MenuItem("Tools/美术工具/TA工具/SSProfile Debug Window")]
        public static void ShowWindow()
        {
            GetWindow<SSProfileDebugWindow>("SSProfile Debug");
        }

        private void OnGUI()
        {
            EditorGUILayout.LabelField("SSProfile LUT Debug Tool", EditorStyles.boldLabel);
            EditorGUILayout.Space();

            _texture = (Texture2D)EditorGUILayout.ObjectField("LUT Texture", _texture, typeof(Texture2D), false);
            _profileId = EditorGUILayout.IntSlider("Profile ID", _profileId, 0, 255);

            if (_texture == null)
            {
                if (SSProfileManager.Instance != null && SSProfileManager.Instance.PackedProfileTexture != null)
                {
                    _texture = SSProfileManager.Instance.PackedProfileTexture;
                }
                else
                {
                    EditorGUILayout.HelpBox("Please assign the SSProfile LUT texture.", MessageType.Warning);
                    return;
                }
            }

            if (! _texture. isReadable)
            {
                EditorGUILayout.HelpBox("Texture is not readable!  Enable Read/Write in import settings.", MessageType.Error);
                if (GUILayout.Button("Fix Import Settings"))
                {
                    FixTextureImportSettings();
                }
                return;
            }

            EditorGUILayout.Space();
            _scrollPos = EditorGUILayout.BeginScrollView(_scrollPos);
            
            DrawProfileData(_profileId);
            
            EditorGUILayout.EndScrollView();
        }

        private void FixTextureImportSettings()
        {
            string path = AssetDatabase.GetAssetPath(_texture);
            TextureImporter importer = AssetImporter.GetAtPath(path) as TextureImporter;
            if (importer != null)
            {
                importer.isReadable = true;
                importer.SaveAndReimport();
            }
        }

        private void DrawProfileData(int profileId)
        {
            EditorGUILayout.LabelField($"=== Profile {profileId} Data ===", EditorStyles.boldLabel);
            EditorGUILayout.Space();

            const int SSSS_TINT_SCALE_OFFSET = 0;
            const int BSSS_SURFACEALBEDO_OFFSET = 1;
            const int BSSS_DMFP_OFFSET = 2;
            const int SSSS_TRANSMISSION_OFFSET = 3;
            const int SSSS_BOUNDARY_COLOR_BLEED_OFFSET = 4;
            const int SSSS_DUAL_SPECULAR_OFFSET = 5;
            const int SSSS_KERNEL0_OFFSET = 6;
            const int SSSS_KERNEL0_SIZE = 13;
            const int BSSS_TRANSMISSION_PROFILE_OFFSET = 34;
            const int BSSS_TRANSMISSION_PROFILE_SIZE = 32;

            const float DEC_WORLDUNITSCALE = 50.0f;
            const float DEC_DMFP = 500.0f;
            const float DEC_EXTINCTION = 100.0f;
            const float SSSS_MAX_DUAL_SPECULAR_ROUGHNESS = 2.0f;

            // 1. Tint & WorldUnitScale
            EditorGUILayout.LabelField("【Tint & Scale】", EditorStyles.boldLabel);
            Color tintScale = _texture.GetPixel(SSSS_TINT_SCALE_OFFSET, profileId);
            EditorGUILayout.ColorField("Raw Tint (RGB)", new Color(tintScale.r, tintScale.g, tintScale.b, 1));
            EditorGUILayout. FloatField("Decoded WorldUnitScale", tintScale.a * DEC_WORLDUNITSCALE);
            EditorGUILayout.Space();

            // 2. Surface Albedo
            EditorGUILayout.LabelField("【Surface Albedo】", EditorStyles. boldLabel);
            Color albedo = _texture.GetPixel(BSSS_SURFACEALBEDO_OFFSET, profileId);
            EditorGUILayout.ColorField("Surface Albedo (RGBA)", albedo);
            EditorGUILayout.LabelField($"  R={albedo.r:F4}, G={albedo.g:F4}, B={albedo.b:F4}, A={albedo.a:F4}");
            EditorGUILayout.Space();

            // 3.  DMFP - 详细显示
            EditorGUILayout.LabelField("【Diffuse Mean Free Path】", EditorStyles.boldLabel);
            Color dmfpEncoded = _texture.GetPixel(BSSS_DMFP_OFFSET, profileId);
            EditorGUILayout.ColorField("Encoded DMFP", dmfpEncoded);
            EditorGUILayout.LabelField($"  Encoded: R={dmfpEncoded.r:F6}, G={dmfpEncoded.g:F6}, B={dmfpEncoded.b:F6}, A={dmfpEncoded.a:F6}");
            
            Color dmfpDecoded = dmfpEncoded * DEC_DMFP;
            EditorGUILayout. ColorField("Decoded DMFP (mm)", dmfpDecoded);
            EditorGUILayout.LabelField($"  Decoded (mm): R={dmfpDecoded.r:F2}, G={dmfpDecoded.g:F2}, B={dmfpDecoded.b:F2}, A={dmfpDecoded.a:F2}");
            
            // 计算并显示 MFP (逆向转换)
            EditorGUILayout.Space();
            EditorGUILayout.LabelField("【MFP 逆向计算验证】", EditorStyles.boldLabel);
            
            // MFP = DMFP × MagicNumber × (Perp / SearchLight) / CmToMm
            float magicNumber = 0.6f;
            Vector3 searchLight = new Vector3(
                GetSearchLightFactor(albedo.r),
                GetSearchLightFactor(albedo. g),
                GetSearchLightFactor(albedo.b)
            );
            Vector3 perp = new Vector3(
                GetPerpFactor(albedo.r),
                GetPerpFactor(albedo.g),
                GetPerpFactor(albedo.b)
            );
            
            EditorGUILayout.LabelField($"  SearchLight Factor: ({searchLight.x:F2}, {searchLight.y:F2}, {searchLight.z:F2})");
            EditorGUILayout.LabelField($"  Perpendicular Factor: ({perp.x:F2}, {perp.y:F2}, {perp.z:F2})");
            
            Vector3 mfpCalculated = new Vector3(
                dmfpDecoded.r * magicNumber * (perp.x / searchLight. x) / 10f,
                dmfpDecoded.g * magicNumber * (perp.y / searchLight. y) / 10f,
                dmfpDecoded.b * magicNumber * (perp.z / searchLight.z) / 10f
            );
            EditorGUILayout.LabelField($"  Calculated MFP (cm): ({mfpCalculated.x:F4}, {mfpCalculated. y:F4}, {mfpCalculated.z:F4})");
            EditorGUILayout.Space();

            // 4. Transmission Params
            EditorGUILayout. LabelField("【Transmission Parameters】", EditorStyles.boldLabel);
            Color transParams = _texture.GetPixel(SSSS_TRANSMISSION_OFFSET, profileId);
            EditorGUILayout.FloatField("Decoded ExtinctionScale", transParams. r * DEC_EXTINCTION);
            EditorGUILayout.FloatField("NormalScale", transParams.g);
            EditorGUILayout. FloatField("Decoded ScatteringDist", transParams. b * 2.0f - 1.0f);
            EditorGUILayout.FloatField("IOR", 1.0f / transParams.a);
            EditorGUILayout.Space();

            // 5. Boundary Color Bleed
            EditorGUILayout.LabelField("【Boundary Color Bleed】", EditorStyles.boldLabel);
            Color boundary = _texture.GetPixel(SSSS_BOUNDARY_COLOR_BLEED_OFFSET, profileId);
            EditorGUILayout.ColorField("Boundary Bleed (RGB)", new Color(boundary.r, boundary. g, boundary.b, 1));
            EditorGUILayout.FloatField("SSS Type (A)", boundary.a);
            EditorGUILayout.Space();

            // 6. Dual Specular
            EditorGUILayout.LabelField("【Dual Specular】", EditorStyles.boldLabel);
            Color dualSpec = _texture.GetPixel(SSSS_DUAL_SPECULAR_OFFSET, profileId);
            EditorGUILayout.FloatField("Decoded Roughness0", dualSpec.r * SSSS_MAX_DUAL_SPECULAR_ROUGHNESS);
            EditorGUILayout.FloatField("Decoded Roughness1", dualSpec.g * SSSS_MAX_DUAL_SPECULAR_ROUGHNESS);
            EditorGUILayout.FloatField("LobeMix", dualSpec. b);
            EditorGUILayout.Space();

            // 7. Kernel 0
            EditorGUILayout.LabelField("【Kernel 0 (13 samples)】", EditorStyles.boldLabel);
            for (int i = 0; i < Mathf.Min(5, SSSS_KERNEL0_SIZE); i++)
            {
                Color k = _texture.GetPixel(SSSS_KERNEL0_OFFSET + i, profileId);
                EditorGUILayout.LabelField($"  Sample {i}: RGB=({k.r:F4}, {k.g:F4}, {k.b:F4}), Offset={k.a:F6}");
            }
            if (SSSS_KERNEL0_SIZE > 5)
                EditorGUILayout.LabelField($"  ...  and {SSSS_KERNEL0_SIZE - 5} more samples");
            EditorGUILayout.Space();

            // 8. Transmission Profile
            EditorGUILayout.LabelField("【Transmission Profile (32 samples)】", EditorStyles.boldLabel);
            for (int i = 0; i < Mathf.Min(8, BSSS_TRANSMISSION_PROFILE_SIZE); i++)
            {
                Color t = _texture.GetPixel(BSSS_TRANSMISSION_PROFILE_OFFSET + i, profileId);
                EditorGUILayout.LabelField($"  Sample {i}: RGB=({t.r:F4}, {t.g:F4}, {t.b:F4}), Shadow={t.a:F4}");
            }
            if (BSSS_TRANSMISSION_PROFILE_SIZE > 8)
                EditorGUILayout. LabelField($"  ... and {BSSS_TRANSMISSION_PROFILE_SIZE - 8} more samples");
        }

        private float GetSearchLightFactor(float albedo)
        {
            float v = albedo - 0.33f;
            return 3.5f + 100f * v * v * v * v;
        }

        private float GetPerpFactor(float albedo)
        {
            float v = Mathf.Abs(albedo - 0.8f);
            return 1.85f - albedo + 7f * v * v * v;
        }
    }
}
#endif
