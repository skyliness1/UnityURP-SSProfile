using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering. Universal;

namespace SoulRender
{
    public class SSProfileRenderFeature : ScriptableRendererFeature
    {
        [System.Serializable]
        public class Settings
        {
            [Header("SSProfile Texture")]
            public Texture2D ssProfileTexture;
            
            [Header("Quality")]
            [Tooltip("0=Low(6 samples), 1=Medium(9 samples), 2=High(13 samples)")]
            [Range(0, 2)]
            public int quality = 1;
            
            [Header("Scale")]
            [Tooltip("控制散射半径，对应 UE5 的 r. SSS.Scale")]
            [Range(0.1f, 5.0f)]
            public float sssScale = 1.0f;
            
            [Header("Depth Threshold")]
            [Tooltip("SSSS_FOLLOW_SURFACE 的深度阈值，值越大边缘越模糊")]
            [Range(0.1f, 50.0f)]
            public float depthThreshold = 30.0f;
            
            [Header("Debug")]
            public DebugMode debugMode = DebugMode.Off;
            public DebugPass debugPass = DebugPass.Final;
        }
        
        public enum DebugMode
        {
            Off = 0,
            ShowUV = 1,
            ShowGBufferD = 2,
            ShowScreenColor = 3,
            ShowShadingModelID = 4,
            ShowSSSMask = 5,
            ShowDepth = 6
        }
        
        public enum DebugPass
        {
            Final = 0,
            SetupOnly = 1,
            BlurOnly = 2
        }

        public Settings settings = new Settings();
        private SSSProcessPass _sssPass;

        public override void Create()
        {
            _sssPass = new SSSProcessPass();
            _sssPass.renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (settings.ssProfileTexture == null)
            {
                return;
            }

            if (renderingData.cameraData.cameraType == CameraType.Preview ||
                renderingData.cameraData.cameraType == CameraType.Reflection)
            {
                return;
            }

            _sssPass.Setup(settings);
            renderer.EnqueuePass(_sssPass);
        }

        protected override void Dispose(bool disposing)
        {
            _sssPass?.Dispose();
        }
    }

    public class SSSProcessPass : ScriptableRenderPass
    {
        private const string PROFILER_TAG = "SSS Profile";
        private SSProfileRenderFeature.Settings _settings;
        
        private Material _setupMaterial;
        private Material _blurMaterial;
        private Material _recombineMaterial;
        
        private RTHandle _setupRT;
        private RTHandle _blurTempRT;
        private RTHandle _blurredRT;
        private RTHandle _screenColorCopyRT;

        // Shader Property IDs
        private static readonly int _BlurDirectionID = Shader.PropertyToID("_BlurDirection");
        private static readonly int _DebugModeID = Shader.PropertyToID("_DebugMode");
        private static readonly int _SSS_ScreenColorID = Shader.PropertyToID("_SSS_ScreenColor");
        private static readonly int _SSS_BlurredResultID = Shader.PropertyToID("_SSS_BlurredResult");
        private static readonly int _SSSParamsID = Shader.PropertyToID("_SSSParams");
        private static readonly int _DepthThresholdID = Shader.PropertyToID("_DepthThreshold");
        private static readonly int _SSProfilesTextureID = Shader.PropertyToID("_SSProfilesTexture");
        private static readonly int _SSProfilesTextureSizeID = Shader. PropertyToID("_SSProfilesTextureSize");

        // UE5 Constants
        private const float SUBSURFACE_RADIUS_SCALE = 1024.0f;
        private const float SUBSURFACE_KERNEL_SIZE = 3.0f;

        public SSSProcessPass()
        {
            
        }

        public void Setup(SSProfileRenderFeature.Settings settings)
        {
            _settings = settings;
            
            if (_setupMaterial == null)
            {
                var shader = Shader.Find("Soul/Scene/SSProfileSetup");
                if (shader != null)
                {
                    _setupMaterial = CoreUtils.CreateEngineMaterial(shader);
                }
                else
                {
                    Debug.LogError("[SSProfile] Cannot find shader: Soul/Scene/SSProfileSetup");
                }
            }
            
            if (_blurMaterial == null)
            {
                var shader = Shader.Find("Soul/Scene/SSProfileBlur");
                if (shader != null)
                {
                    _blurMaterial = CoreUtils.CreateEngineMaterial(shader);
                }
                else
                {
                    Debug.LogError("[SSProfile] Cannot find shader: Soul/Scene/SSProfileBlur");
                }
            }
            
            if (_recombineMaterial == null)
            {
                var shader = Shader.Find("Soul/Scene/SSProfileRecombine");
                if (shader != null)
                {
                    _recombineMaterial = CoreUtils.CreateEngineMaterial(shader);
                }
                else
                {
                    Debug.LogError("[SSProfile] Cannot find shader: Soul/Scene/SSProfileRecombine");
                }
            }
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0;
            desc.msaaSamples = 1;
            desc.graphicsFormat = UnityEngine.Experimental.Rendering.GraphicsFormat. R16G16B16A16_SFloat;
            
            RenderingUtils.ReAllocateIfNeeded(ref _setupRT, desc, FilterMode.Bilinear, 
                TextureWrapMode.Clamp, name: "_SSS_SetupRT");
            RenderingUtils.ReAllocateIfNeeded(ref _blurTempRT, desc, FilterMode.Bilinear, 
                TextureWrapMode.Clamp, name: "_SSS_BlurTempRT");
            RenderingUtils.ReAllocateIfNeeded(ref _blurredRT, desc, FilterMode.Bilinear, 
                TextureWrapMode.Clamp, name: "_SSS_BlurredRT");
            RenderingUtils.ReAllocateIfNeeded(ref _screenColorCopyRT, desc, FilterMode.Bilinear, 
                TextureWrapMode.Clamp, name: "_SSS_ScreenColorCopy");
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_setupMaterial == null || _blurMaterial == null || _recombineMaterial == null)
            {
                return;
            }

            if (_settings.ssProfileTexture == null)
            {
                return;
            }

            var cmd = CommandBufferPool.Get(PROFILER_TAG);
            
            try
            {
                ExecutePass(cmd, ref renderingData);
            }
            finally
            {
                context.ExecuteCommandBuffer(cmd);
                CommandBufferPool.Release(cmd);
            }
        }
        
        private void ExecutePass(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var cameraData = renderingData. cameraData;
            var source = cameraData.renderer.cameraColorTargetHandle;
            
            // 设置全局参数
            SetupGlobalParameters(cmd, cameraData);
            
            float debugMode = (float)_settings.debugMode;
            
            // ================================================================
            // 复制原始场景颜色，用于 Recombine 阶段
            // ================================================================
            Blitter.BlitCameraTexture(cmd, source, _screenColorCopyRT);
            
            // ================================================================
            // Pass 0: Setup - 提取 Diffuse 和 Depth
            // ================================================================
            _setupMaterial.SetFloat(_DebugModeID, debugMode);
            Blitter.BlitCameraTexture(cmd, source, _setupRT, _setupMaterial, 0);
            
            if (_settings.debugPass == SSProfileRenderFeature.DebugPass.SetupOnly)
            {
                Blitter.BlitCameraTexture(cmd, _setupRT, source);
                return;
            }
            
            // ================================================================
            // Pass 1: Horizontal Blur
            // UE5: ViewportDirectionUV = float2(1, 0) * SUBSURFACE_RADIUS_SCALE
            // ================================================================
            _blurMaterial.SetFloat(_DebugModeID, debugMode);
            _blurMaterial.SetVector(_BlurDirectionID, new Vector4(SUBSURFACE_RADIUS_SCALE, 0, 0, 0));
            Blitter.BlitCameraTexture(cmd, _setupRT, _blurTempRT, _blurMaterial, 0);
            
            // ================================================================
            // Pass 2: Vertical Blur
            // UE5: ViewportDirectionUV = float2(0, 1) * SUBSURFACE_RADIUS_SCALE * aspectRatio
            // ================================================================
            float aspectRatio = (float)cameraData.camera.pixelWidth / cameraData.camera.pixelHeight;
            _blurMaterial.SetVector(_BlurDirectionID, new Vector4(0, SUBSURFACE_RADIUS_SCALE * aspectRatio, 0, 0));
            Blitter.BlitCameraTexture(cmd, _blurTempRT, _blurredRT, _blurMaterial, 0);
            
            if (_settings.debugPass == SSProfileRenderFeature.DebugPass.BlurOnly)
            {
                Blitter.BlitCameraTexture(cmd, _blurredRT, source);
                return;
            }
            
            // ================================================================
            // Pass 3: Recombine - 合并模糊的 Diffuse 和原始 Specular
            // ================================================================
            _recombineMaterial.SetFloat(_DebugModeID, debugMode);
            
            // 设置纹理
            cmd.SetGlobalTexture(_SSS_ScreenColorID, _screenColorCopyRT);
            cmd.SetGlobalTexture(_SSS_BlurredResultID, _blurredRT);
            
            // 直接输出到 source
            Blitter.BlitCameraTexture(cmd, _screenColorCopyRT, source, _recombineMaterial, 0);
        }

        private void SetupGlobalParameters(CommandBuffer cmd, CameraData cameraData)
        {
            // 设置 Profile 纹理
            cmd. SetGlobalTexture(_SSProfilesTextureID, _settings. ssProfileTexture);
            cmd.SetGlobalVector(_SSProfilesTextureSizeID, new Vector4(
                _settings.ssProfileTexture.width, 
                _settings.ssProfileTexture. height,
                1.0f / _settings.ssProfileTexture.width, 
                1.0f / _settings.ssProfileTexture. height
            ));
            
            // ============================================================
            // UE5 参数计算
            // ============================================================
            
            float tanHalfFov = Mathf.Tan(cameraData.camera.fieldOfView * Mathf.Deg2Rad * 0.5f);
            float projectionDistance = 1.0f / tanHalfFov;
            
            float sssScaleX = _settings.sssScale * projectionDistance;
            
            // Kernel 大小
            int kernelSampleCount = _settings.quality switch
            {
                2 => 13,  // High
                1 => 9,   // Medium
                _ => 6    // Low
            };
            
            cmd.SetGlobalVector(_SSSParamsID, new Vector4(
                sssScaleX, projectionDistance, 0, _settings.quality
            ));
            
            cmd.SetGlobalFloat(_DepthThresholdID, _settings.depthThreshold);
        }

        public void Dispose()
        {
            _setupRT?.Release();
            _blurTempRT?.Release();
            _blurredRT?.Release();
            _screenColorCopyRT?.Release();
            
            CoreUtils.Destroy(_setupMaterial);
            CoreUtils.Destroy(_blurMaterial);
            CoreUtils.Destroy(_recombineMaterial);
        }
    }
}
