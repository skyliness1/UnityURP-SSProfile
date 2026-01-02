using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering. Universal;

namespace SoulRender
{
    /// <summary>
    /// SSProfile 渲染功能（Compute Shader 版本）
    /// 当前阶段：仅测试 Setup Pass
    /// </summary>
    public class SSProfileRenderFeature :  ScriptableRendererFeature
    {
        [System.Serializable]
        public class Settings
        {
            [Header("Render Pass Event")]
            public RenderPassEvent renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;

            [Header("Compute Shaders")]
            public ComputeShader setupCS;
            public ComputeShader blurCS;  
            public ComputeShader indirectArgsCS;
            public Shader recombineShader;
            
            [Header("SSProfile Settings")]
            [Tooltip("SSProfile LUT 纹理（从 SSProfileManager 生成）")]
            public Texture2D profileLUT;

            [Header("Quality Settings")]
            [Tooltip("使用半分辨率以提升性能")]
            public bool useHalfResolution = false;
            
            [Tooltip("使用 Indirect Dispatch（仅处理有 SSS 的 Tile，性能提升 2-3x）")]
            public bool useIndirectDispatch = true;
            
            [Range(0.1f, 2.0f)]
            public float sssIntensity = 1.0f;

            [Header("Debug Visualization")]
            [Tooltip("可视化 Setup Pass 输出")]
            public bool enableDebugView = true;

            [Tooltip("Debug 显示模式")]
            public DebugViewMode debugMode = DebugViewMode.Diffuse;

            public enum DebugViewMode
            {
                Diffuse,        // 显示分离后的 Diffuse
                Specular,       // 显示分离后的 Specular
                ProfileID,      // 显示 ProfileID（伪彩色）
                Depth,          // 显示深度
                TileMask,        // 显示有 SSS 的 Tile（调试用）
                BlurComparison,      // ✅ 新增：分屏对比
                ScatteredDiffuse 
            }
        }

        public Settings settings = new Settings();

        private SSProfileSetupRenderPass _setupPass;
        private SSProfileBlurRenderPass _blurPass;
        private SSProfileRecombineRenderPass _recombinePass;
        private SSProfileDebugRenderPass _debugPass;  // 用于可视化输出

        public override void Create()
        {
            if (settings.setupCS == null)
            {
                Debug.LogError("[SSProfileRenderFeature] Setup Compute Shader is missing!");
                return;
            }
            
            if (settings.profileLUT == null)
            {
                Debug.LogWarning("[SSProfileRenderFeature] Profile LUT texture is not assigned!  SSS will not work correctly.");
            }

            // 创建 Setup Pass
            _setupPass = new SSProfileSetupRenderPass(settings);
            
            if (settings.blurCS != null)
            {
                _blurPass = new SSProfileBlurRenderPass(
                    settings, 
                    settings.blurCS, 
                    _setupPass,
                    settings.indirectArgsCS 
                );
            }
            
            if (settings.recombineShader != null)
            {
                _recombinePass = new SSProfileRecombineRenderPass(settings, settings.recombineShader);
            }

            // 创建 Debug Pass（用于可视化）
            if (settings.enableDebugView)
            {
                _debugPass = new SSProfileDebugRenderPass(settings);
            }
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (!IsActive(ref renderingData))
            {
                return;
            }
            
            BindSSProfileLUT();

            // 添加 Setup Pass
            renderer.EnqueuePass(_setupPass);
            
            if (_blurPass != null)
            {
                renderer.EnqueuePass(_blurPass);
            }
            
            if (_recombinePass != null && ! settings.enableDebugView)
            {
                renderer.EnqueuePass(_recombinePass);
            }

            // 添加 Debug Pass（可视化输出）
            if (settings.enableDebugView && _debugPass != null)
            {
                renderer.EnqueuePass(_debugPass);
            }
        }

        private bool IsActive(ref RenderingData renderingData)
        {
            var cameraData = renderingData.cameraData;

            // 只在主相机和 Scene 视图中执行
            if (cameraData.cameraType != CameraType.Game && cameraData.cameraType != CameraType.SceneView)
            {
                return false;
            }

            // 检查 Compute Shader
            if (settings.setupCS == null)
            {
                return false;
            }
            
            return true;
        }
        
        /// <summary>
        /// 绑定 SSProfile LUT 纹理到全局 Shader 属性
        /// </summary>
        private void BindSSProfileLUT()
        {
            if (settings.profileLUT == null)
            {
                // LUT 未分配，使用黑色纹理作为 fallback
                Shader.SetGlobalTexture("_SubsurfaceProfileTexture", Texture2D.blackTexture);
                return;
            }
            
            Shader.SetGlobalTexture("_SubsurfaceProfileTexture", settings.profileLUT);
            
            Shader.SetGlobalVector("_SubsurfaceProfileTexture_TexelSize", new Vector4(
                settings.profileLUT.width,
                settings.profileLUT. height,
                1.0f / settings.profileLUT.width,
                1.0f / settings.profileLUT. height
            ));
        }

        protected override void Dispose(bool disposing)
        {
            _setupPass?.Dispose();
            _blurPass?.Dispose();
            _recombinePass?.Dispose();
            _debugPass?.Dispose();
        }
    }
}
