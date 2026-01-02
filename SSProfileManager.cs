using UnityEngine;
using UnityEditor;
using System.Collections.Generic;
using System.IO;
using System;

namespace SoulRender
{
    [InitializeOnLoad]
    public static class SSProfileBridge
    {
        private static bool _pendingTextureUpdate = false;
        private static double _lastUpdateTime = 0;
        private const double UPDATE_DEBOUNCE_TIME = 0.5;

        static SSProfileBridge()
        {
            SSProfileSettings.OnSettingsChanged += OnProfileSettingsChanged;
            EditorApplication.delayCall += InitializeOnStartup;
        }

        private static void InitializeOnStartup()
        {
            var manager = SSProfileManager.Instance;
            if (manager != null && manager.PackedProfileTexture == null)
            {
                Debug.Log("[SSProfileBridge] Initializing SSProfile system...");
                manager.RefreshProfiles();
            }
        }

        private static void OnProfileSettingsChanged(SSProfileSettings settings)
        {
            if (settings == null)
            {
                return;
            }
            
            double currentTime = EditorApplication.timeSinceStartup;
            if (currentTime - _lastUpdateTime < UPDATE_DEBOUNCE_TIME)
            {
                if (_pendingTextureUpdate)
                {
                    return;
                }
            }

            _pendingTextureUpdate = true;
            _lastUpdateTime = currentTime;

            EditorApplication.delayCall += () =>
            {
                if (!_pendingTextureUpdate)
                {
                    return;
                }
                _pendingTextureUpdate = false;

                if (SSProfileManager.Instance != null)
                {
                    SSProfileManager.Instance.GenerateTexture();
                }
            };
        }
    }

    [CreateAssetMenu(fileName = "SSProfileManager", menuName = "SSProfile/SSProfile Manager")]
    public class SSProfileManager : ScriptableObject
    {
        private const string ManagerAssetPath = "Assets/Scripts/Soul/Rendering/Enviroment/SSProfile/Settings/SSProfileManager.asset";

        [HideInInspector]
        [SerializeField]
        private List<SSProfileSettings> registeredProfiles = new List<SSProfileSettings>();

        [HideInInspector]
        [SerializeField] 
        private Texture2D _packedProfileTexture; 

        private SSProfileSettings _runtimeDefaultProfile;
        private List<SSProfileSettings> _cachedBakeList;

        private static SSProfileManager _instance;

        public static SSProfileManager Instance
        {
            get
            {
                if (_instance == null)
                {
                    _instance = GetOrCreateInstance();
                }
                return _instance;
            }
        }
        
        public Texture2D PackedProfileTexture => _packedProfileTexture;
        public List<SSProfileSettings> RegisteredProfiles => registeredProfiles;

        private void OnEnable()
        {
            _instance = this;
            ValidateList();
        }

        private void ValidateList()
        {
            for (int i = registeredProfiles.Count - 1; i >= 0; i--)
            {
                if (registeredProfiles[i] == null)
                {
                    registeredProfiles.RemoveAt(i);
                }
            }
        }

        private static SSProfileManager GetOrCreateInstance()
        {
            var instance = AssetDatabase.LoadAssetAtPath<SSProfileManager>(ManagerAssetPath);
            if (instance != null)
            {
                return instance;
            }

            string[] guids = AssetDatabase.FindAssets("t:SSProfileManager");
            if (guids.Length > 0)
            {
                string path = AssetDatabase.GUIDToAssetPath(guids[0]);
                instance = AssetDatabase.LoadAssetAtPath<SSProfileManager>(path);
                if (instance != null)
                {
                    return instance;
                }
            }

            try
            {
                string directory = Path.GetDirectoryName(ManagerAssetPath);
                if (!string.IsNullOrEmpty(directory) && ! Directory.Exists(directory))
                {
                    Directory.CreateDirectory(directory);
                    AssetDatabase.Refresh();
                }

                instance = ScriptableObject.CreateInstance<SSProfileManager>();
                AssetDatabase.CreateAsset(instance, ManagerAssetPath);
                AssetDatabase.SaveAssets();
                AssetDatabase.Refresh();
                
                Debug.Log($"[SSProfileManager] Created new manager at: {ManagerAssetPath}");
                
                EditorApplication.delayCall += () =>
                {
                    if (instance != null)
                    {
                        instance.RefreshProfiles();
                    }
                };
            }
            catch (Exception e)
            {
                Debug.LogError($"[SSProfileManager] Failed to create manager: {e.Message}");
                return null;
            }
            
            return instance;
        }

        public SSProfileSettings DefaultProfile
        {
            get
            {
                if (_runtimeDefaultProfile == null)
                {
                    _runtimeDefaultProfile = ScriptableObject.CreateInstance<SSProfileSettings>();
                    _runtimeDefaultProfile.name = "System_Default_Profile (ID: 0)";
                    _runtimeDefaultProfile.hideFlags = HideFlags.HideAndDontSave;
                    
                    _runtimeDefaultProfile.surfaceAlbedo = new Color(0.91f, 0.34f, 0.27f);
                    _runtimeDefaultProfile.meanFreePathColor = new Color(1.0f, 0.09f, 0.07f);
                    _runtimeDefaultProfile.meanFreePathDistance = 2.6f;
                    _runtimeDefaultProfile.worldUnitScale = 1.0f;
                    _runtimeDefaultProfile.tint = Color.white;
                    _runtimeDefaultProfile.boundaryColorBleed = Color.white;
                    _runtimeDefaultProfile.transmissionTintColor = Color.white;
                    _runtimeDefaultProfile.extinctionScale = 1.0f;
                    _runtimeDefaultProfile.normalScale = 0.08f;
                    _runtimeDefaultProfile.scatteringDistribution = 0.93f;
                    _runtimeDefaultProfile.IOR = 1.55f;
                    _runtimeDefaultProfile.roughness0 = 0.5f;
                    _runtimeDefaultProfile.roughness1 = 1.20f;
                    _runtimeDefaultProfile.lobeMix = 0.85f;
                    
                    _runtimeDefaultProfile.SetProfileId(0);
                }
                return _runtimeDefaultProfile;
            }
        }

        public List<SSProfileSettings> GetAllProfilesForTextureGeneration()
        {
            if (_cachedBakeList == null)
            {
                _cachedBakeList = new List<SSProfileSettings>();
            }
            else
            {
                _cachedBakeList.Clear();
            }
            
            _cachedBakeList.Add(DefaultProfile);
            
            for (int i = 0; i < registeredProfiles. Count; i++)
            {
                if (registeredProfiles[i] != null)
                {
                    _cachedBakeList.Add(registeredProfiles[i]);
                } 
            }
            return _cachedBakeList;
        }

        public void RefreshProfiles()
        {
            string[] guids = AssetDatabase.FindAssets("t:SSProfileSettings");
            HashSet<SSProfileSettings> allOnDisk = new HashSet<SSProfileSettings>();

            for (int i = 0; i < guids.Length; i++)
            {
                string path = AssetDatabase.GUIDToAssetPath(guids[i]);
                var profile = AssetDatabase.LoadAssetAtPath<SSProfileSettings>(path);
                if (profile != null && EditorUtility.IsPersistent(profile))
                {
                    allOnDisk.Add(profile);
                }
            }

            bool listChanged = false;

            for (int i = registeredProfiles.Count - 1; i >= 0; i--)
            {
                if (registeredProfiles[i] == null || !allOnDisk.Contains(registeredProfiles[i]))
                {
                    registeredProfiles.RemoveAt(i);
                    listChanged = true;
                }
            }

            List<SSProfileSettings> newAssets = new List<SSProfileSettings>();
            foreach (var profile in allOnDisk)
            {
                if (!registeredProfiles.Contains(profile))
                {
                    newAssets.Add(profile);
                }
            }

            if (newAssets.Count > 0)
            {
                newAssets.Sort((a, b) => string.Compare(a.name, b.name));
                Undo.RecordObject(this, "Refresh Profile List");
                registeredProfiles.AddRange(newAssets);
                listChanged = true;
                Debug.Log($"[SSProfileManager] Added {newAssets.Count} new profiles");
            }

            bool idChanged = false;
            for (int i = 0; i < registeredProfiles.Count; i++)
            {
                var profile = registeredProfiles[i];
                if (profile == null)
                {
                    continue;
                }

                int targetId = i + 1;
                if (profile.ProfileId != targetId)
                {
                    profile.SetProfileId(targetId);
                    idChanged = true;
                }
            }

            if (listChanged || idChanged || _packedProfileTexture == null)
            {
                _cachedBakeList = null;
                EditorUtility.SetDirty(this);
                AssetDatabase.SaveAssets();
                
                GenerateTexture();
            }
        }

        public void GenerateTexture()
        {
            try
            {
                SSProfileTextureGenerator.UpdatePackedTexture(this, ref _packedProfileTexture);
                EditorUtility.SetDirty(this);
                AssetDatabase.SaveAssets();
            }
            catch (Exception e)
            {
                Debug.LogError($"[SSProfileManager] Failed to generate texture: {e.Message}\n{e.StackTrace}");
            }
        }
    }

    [CustomEditor(typeof(SSProfileManager))]
    public class SSProfileManagerEditor : Editor
    {
        private SerializedProperty _registeredProfiles;
        private SerializedProperty _packedProfileTexture;

        private void OnEnable()
        {
            _registeredProfiles = serializedObject.FindProperty("registeredProfiles");
            _packedProfileTexture = serializedObject.FindProperty("_packedProfileTexture");
        }

        public override void OnInspectorGUI()
        {
            serializedObject.Update();
            SSProfileManager manager = (SSProfileManager)target;

            EditorGUILayout.Space(10);
            EditorGUILayout.LabelField("Global SSProfile Settings", EditorStyles.boldLabel);
            EditorGUILayout.HelpBox("IDs are assigned based on registration order.", MessageType.Info);

            EditorGUILayout.Space(5);
            DrawReadOnlyList();

            EditorGUILayout.Space(10);
            
            EditorGUI.BeginDisabledGroup(true);
            EditorGUILayout.PropertyField(_packedProfileTexture, new GUIContent("Packed Texture"));
            EditorGUI.EndDisabledGroup();
            
            if (manager.PackedProfileTexture != null)
            {
                EditorGUILayout.LabelField("Texture Size", $"{manager.PackedProfileTexture.width} x {manager.PackedProfileTexture.height}");
            }
            else
            {
                EditorGUILayout.HelpBox("Texture not generated yet!", MessageType.Warning);
            }

            EditorGUILayout.Space(20);

            using (new EditorGUILayout.HorizontalScope())
            {
                if (GUILayout.Button("Refresh Profiles", GUILayout.Height(30)))
                {
                    manager.RefreshProfiles();
                }
                
                if (GUILayout.Button("Regenerate Texture", GUILayout. Height(30)))
                {
                    manager.GenerateTexture();
                }
            }

            serializedObject.ApplyModifiedProperties();
        }

        private void DrawReadOnlyList()
        {
            EditorGUILayout.LabelField($"Registered Profiles ({_registeredProfiles.arraySize})", EditorStyles.boldLabel);
            
            if (_registeredProfiles.arraySize == 0)
            {
                EditorGUILayout.HelpBox("No profiles registered. Create SSProfileSettings assets and click 'Refresh Profiles'.", MessageType.Info);
                return;
            }
            
            EditorGUI.indentLevel++;
            GUI.enabled = false;

            for (int i = 0; i < _registeredProfiles.arraySize; i++)
            {
                SerializedProperty element = _registeredProfiles.GetArrayElementAtIndex(i);
                SSProfileSettings profile = element.objectReferenceValue as SSProfileSettings;
                string label = $"ID {i + 1}:  {(profile != null ? profile.name : "Missing/Null")}";
                EditorGUILayout.PropertyField(element, new GUIContent(label));
            }

            GUI.enabled = true;
            EditorGUI.indentLevel--;
        }
    }

    public class SSProfileAssetPostprocessor : AssetPostprocessor
    {
        private static HashSet<string> _knownSSProfilePaths = new HashSet<string>();
        private static bool _initialized = false;
        private static bool _needsRefresh = false;

        private static void EnsureInitialized()
        {
            if (_initialized)
            {
                return;
            }
            _initialized = true;
            
            string[] guids = AssetDatabase.FindAssets("t:SSProfileSettings");
            foreach (var guid in guids)
            {
                _knownSSProfilePaths.Add(AssetDatabase.GUIDToAssetPath(guid));
            }
        }

        private static void OnPostprocessAllAssets(string[] imported, string[] deleted, string[] moved, string[] movedFrom)
        {
            EnsureInitialized();
            
            bool hasRelevantChange = false;

            foreach (var path in imported)
            {
                if (!path.EndsWith(".asset", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                
                var asset = AssetDatabase.LoadAssetAtPath<SSProfileSettings>(path);
                if (asset != null)
                {
                    if (! _knownSSProfilePaths.Contains(path))
                    {
                        _knownSSProfilePaths.Add(path);
                        hasRelevantChange = true;
                        Debug.Log($"[SSProfile] New profile detected: {path}");
                    }
                }
            }

            foreach (var path in deleted)
            {
                if (_knownSSProfilePaths.Contains(path))
                {
                    _knownSSProfilePaths.Remove(path);
                    hasRelevantChange = true;
                    Debug.Log($"[SSProfile] Profile deleted: {path}");
                }
            }

            for (int i = 0; i < moved.Length && i < movedFrom.Length; i++)
            {
                if (_knownSSProfilePaths.Contains(movedFrom[i]))
                {
                    _knownSSProfilePaths.Remove(movedFrom[i]);
                    _knownSSProfilePaths.Add(moved[i]);
                }
            }

            if (hasRelevantChange && ! _needsRefresh)
            {
                _needsRefresh = true;
                EditorApplication.delayCall += TriggerRefresh;
            }
        }

        private static void TriggerRefresh()
        {
            _needsRefresh = false;
            
            EditorApplication.delayCall += () =>
            {
                var manager = SSProfileManager.Instance;
                if (manager != null)
                {
                    manager.RefreshProfiles();
                }
            };
        }
    }
}
