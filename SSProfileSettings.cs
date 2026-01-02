using UnityEngine;
#if UNITY_EDITOR
using UnityEditor;
#endif

namespace SoulRender
{
    [CreateAssetMenu(fileName = "New Subsurface Profile Settings", menuName = "SSProfile/SSProfile Settings")]
    public class SSProfileSettings : ScriptableObject
    {
        [Header("Profile ID")]
        [Tooltip("全局ID，对应预积分纹理的行号 (V坐标)。由 Manager 自动管理，不可手动修改。")]
        [SerializeField, ReadOnlyInspector] 
        private int _profileId = -1;

        public int ProfileId => _profileId;
        
        [Header("SSS Parameters (Burley Normalized)")]
        [Tooltip("材质的基础颜色。应尽可能与 Albedo 贴图保持一致。")]
        public Color surfaceAlbedo = new Color(0.91f, 0.34f, 0.27f);
        
        [Tooltip("控制光线在 RGB 通道中进入次表面的深度权重。会受到 MFP Distance 的缩放影响。")]
        public Color meanFreePathColor = new Color(1.0f, 0.089f, 0.072f);
        
        [Tooltip("次表面平均自由程距离 (世界单位 cm)。控制透光的整体范围。")]
        [Range(0.1f, 50.0f)] 
        public float meanFreePathDistance = 2.67f;
        
        [Tooltip("世界单位缩放比例。默认 0.1 表示 1 Unreal Unit = 0.1 cm。")]
        [Range(0.1f, 50.0f)] 
        public float worldUnitScale = 0.1f;
        
        [Tooltip("原始漫反射与 SSS 过滤图像之间的混合系数。")]
        public Color tint = Color.white;
        
        [Tooltip("边界处的颜色溢出控制 (Per-channel falloff)。")]
        public Color boundaryColorBleed = Color.white;
        
        [Header("Transmission")]
        [Tooltip("透射 (背光) 的染色。")]
        public Color transmissionTintColor = Color.white;

        [Tooltip("消光系数，控制透射衰减速度。")]
        [Range(0.01f, 100.0f)] 
        public float extinctionScale = 1.0f;

        [Tooltip("法线扰动系数，影响透射光方向。")]
        [Range(0.01f, 1.0f)] 
        public float normalScale = 0.08f;

        [Tooltip("散射分布 (各向异性因子)。")]
        [Range(0.01f, 1.0f)] 
        public float scatteringDistribution = 0.93f;

        [Tooltip("折射率 (Index of Refraction)。")]
        [Range(1.0f, 3.0f)] 
        public float IOR = 1.55f;

        [Header("Dual Specular")]
        [Tooltip("第一层高光粗糙度。")]
        [Range(0.5f, 2.0f)] 
        public float roughness0 = 0.75f;

        [Tooltip("第二层高光粗糙度。")]
        [Range(0.5f, 2.0f)] 
        public float roughness1 = 1.30f;

        [Tooltip("两层高光的混合权重。")]
        [Range(0.1f, 0.9f)] 
        public float lobeMix = 0.85f;
        
        public void SetProfileId(int id)
        {
            if (_profileId != id)
            {
#if UNITY_EDITOR
                Undo.RecordObject(this, "Update Profile ID");
#endif
                _profileId = id;
#if UNITY_EDITOR
                EditorUtility.SetDirty(this);
#endif
            }
        }

#if UNITY_EDITOR
        public static event System.Action<SSProfileSettings> OnSettingsChanged;
        
        private bool _pendingNotification = false;

        private void OnValidate()
        {
            if (!Application.isPlaying && !_pendingNotification)
            {
                _pendingNotification = true;
                EditorApplication.delayCall += NotifyChange;
            }
        }

        private void NotifyChange()
        {
            _pendingNotification = false;

            if (this == null)
            {
                return;
            }
            
            OnSettingsChanged?.Invoke(this);
        }
#endif
    }
    
#if UNITY_EDITOR
    public class ReadOnlyInspectorAttribute : PropertyAttribute { }

    [CustomPropertyDrawer(typeof(ReadOnlyInspectorAttribute))]
    public class ReadOnlyInspectorDrawer : PropertyDrawer
    {
        public override void OnGUI(Rect position, SerializedProperty property, GUIContent label)
        {
            EditorGUI.BeginDisabledGroup(true);
            EditorGUI.PropertyField(position, property, label, true);
            EditorGUI.EndDisabledGroup();
        }
    }

    [CustomEditor(typeof(SSProfileSettings))]
    public class SSProfileSettingsEditor : Editor
    {
        SerializedProperty _profileId;
        SerializedProperty _surfaceAlbedo;
        SerializedProperty _meanFreePathColor;
        SerializedProperty _meanFreePathDistance;
        SerializedProperty _worldUnitScale;
        SerializedProperty _tint;
        SerializedProperty _boundaryColorBleed;
        
        SerializedProperty _transmissionTintColor;
        SerializedProperty _extinctionScale;
        SerializedProperty _normalScale;
        SerializedProperty _scatteringDistribution;
        SerializedProperty _ior;
        
        SerializedProperty _roughness0;
        SerializedProperty _roughness1;
        SerializedProperty _lobeMix;

        private void OnEnable()
        {
            _profileId = serializedObject.FindProperty("_profileId");
            _surfaceAlbedo = serializedObject.FindProperty(nameof(SSProfileSettings.surfaceAlbedo));
            _meanFreePathColor = serializedObject.FindProperty(nameof(SSProfileSettings.meanFreePathColor));
            _meanFreePathDistance = serializedObject.FindProperty(nameof(SSProfileSettings.meanFreePathDistance));
            _worldUnitScale = serializedObject.FindProperty(nameof(SSProfileSettings.worldUnitScale));
            _tint = serializedObject.FindProperty(nameof(SSProfileSettings.tint));
            _boundaryColorBleed = serializedObject.FindProperty(nameof(SSProfileSettings.boundaryColorBleed));
            
            _transmissionTintColor = serializedObject.FindProperty(nameof(SSProfileSettings.transmissionTintColor));
            _extinctionScale = serializedObject.FindProperty(nameof(SSProfileSettings.extinctionScale));
            _normalScale = serializedObject.FindProperty(nameof(SSProfileSettings.normalScale));
            _scatteringDistribution = serializedObject.FindProperty(nameof(SSProfileSettings.scatteringDistribution));
            _ior = serializedObject.FindProperty(nameof(SSProfileSettings.IOR));
            
            _roughness0 = serializedObject.FindProperty(nameof(SSProfileSettings.roughness0));
            _roughness1 = serializedObject.FindProperty(nameof(SSProfileSettings.roughness1));
            _lobeMix = serializedObject.FindProperty(nameof(SSProfileSettings.lobeMix));
        }

        public override void OnInspectorGUI()
        {
            serializedObject.Update();

            EditorGUILayout.LabelField("核心设置 (System)", EditorStyles.boldLabel);
            EditorGUILayout.PropertyField(_profileId, new GUIContent("Profile ID (行号)"));
            EditorGUILayout.Space(5);

            EditorGUILayout.LabelField("SSS 参数", EditorStyles.boldLabel);
            DrawProp(_surfaceAlbedo, "表面反照率 (Surface Albedo)");
            DrawProp(_meanFreePathColor, "平均自由程颜色 (MFP Color)");
            DrawProp(_meanFreePathDistance, "平均自由程距离 (MFP Distance, cm)");
            DrawProp(_worldUnitScale, "世界单位缩放 (World Unit Scale)");
            DrawProp(_tint, "散射染色 (Tint)");
            DrawProp(_boundaryColorBleed, "边界溢色 (Boundary Bleed)");
            EditorGUILayout.Space(5);

            EditorGUILayout.LabelField("透射参数 (Transmission)", EditorStyles.boldLabel);
            DrawProp(_transmissionTintColor, "透射颜色 (Tint)");
            DrawProp(_extinctionScale, "消光系数 (Extinction)");
            DrawProp(_normalScale, "法线扭曲 (Normal Scale)");
            DrawProp(_scatteringDistribution, "透射分布 (Distribution)");
            DrawProp(_ior, "折射率 (IOR)");
            EditorGUILayout.Space(5);

            EditorGUILayout.LabelField("双叶高光 (Dual Specular)", EditorStyles.boldLabel);
            DrawProp(_roughness0, "粗糙度 A (Roughness 0)");
            DrawProp(_roughness1, "粗糙度 B (Roughness 1)");
            DrawProp(_lobeMix, "混合权重 (Lobe Mix)");

            serializedObject.ApplyModifiedProperties();
        }

        private void DrawProp(SerializedProperty prop, string label)
        {
            if (prop != null)
            {
                EditorGUILayout.PropertyField(prop, new GUIContent(label));
            }
        }
    }
#endif
}
