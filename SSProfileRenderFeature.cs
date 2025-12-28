using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

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
            [Range(0, 2)]
            public int quality = 1;
            
            [Header("Scale")]
            [Range(0.0f, 3.0f)]
            public float sssScale = 1.0f;
            
            [Header("Bilateral Filter")]
            [Range(0.1f, 10.0f)]
            public float depthThreshold = 1.0f;
            
            [Header("Debug")]
            public DebugMode debugMode = DebugMode.Off;
        }
        
        public enum DebugMode
        {
            Off = 0,
            Checkerboard = 1,
            DiffuseOnly = 2,
            SpecularOnly = 3,
            SSSMask = 4
        }

        public Settings settings = new Settings();
        private SSSProcessPass _sssPass;

        public override void Create()
        {
            _sssPass = new SSSProcessPass(settings);
            // 必须在 Deferred Lighting 之后执行
            _sssPass.renderPassEvent = RenderPassEvent.AfterRenderingDeferredLights;
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (settings.ssProfileTexture == null) return;
            if (renderingData.cameraData.cameraType == CameraType.Preview || renderingData.cameraData.cameraType == CameraType.Reflection) return;

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
        private Material _blurMaterial;
        private Material _recombineMaterial;
        
        private RTHandle _blurTempRT;
        private RTHandle _blurredRT;
        private RTHandle _finalRT;
        
        // 定义显式的全局纹理 ID，避免使用 _MainTex 造成的混淆
        private static readonly int _Soul_ScreenColor_ID = Shader.PropertyToID("_Soul_ScreenColor");
        private static readonly int _SSSBlurredRT_ID = Shader.PropertyToID("_SSSBlurredRT");

        public SSSProcessPass(SSProfileRenderFeature.Settings settings)
        {
            _settings = settings;
            var blurShader = Shader.Find("Soul/Scene/SSProfileBlur");
            if (blurShader != null) _blurMaterial = CoreUtils.CreateEngineMaterial(blurShader);
            
            var recombineShader = Shader.Find("Soul/Scene/SSProfileRecombine");
            if (recombineShader != null) _recombineMaterial = CoreUtils.CreateEngineMaterial(recombineShader);
        }

        public void Setup(SSProfileRenderFeature.Settings settings)
        {
            _settings = settings;
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0;
            desc.msaaSamples = 1;
            desc.colorFormat = RenderTextureFormat.ARGBHalf;
            
            RenderingUtils.ReAllocateIfNeeded(ref _blurTempRT, desc, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_SSSBlurTemp");
            RenderingUtils.ReAllocateIfNeeded(ref _blurredRT, desc, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_SSSBlurredRT");
            RenderingUtils.ReAllocateIfNeeded(ref _finalRT, desc, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_SSSFinalRT");
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_blurMaterial == null || _recombineMaterial == null || _settings.ssProfileTexture == null) return;

            var cmd = CommandBufferPool.Get(PROFILER_TAG);
            var cameraData = renderingData.cameraData;
            
            // 获取当前屏幕内容
            RTHandle sourceHandle = renderingData.cameraData.renderer.cameraColorTargetHandle;

            SetupGlobalParameters(cmd, cameraData, cameraData.cameraTargetDescriptor);
            
            // ================================================================
            // 关键修复：显式设置全局纹理，Shader 中使用 _Soul_ScreenColor 读取
            // ================================================================
            cmd.SetGlobalTexture(_Soul_ScreenColor_ID, sourceHandle);

            // Pass 1: 水平模糊
            // 输入: _Soul_ScreenColor (Global)
            // 输出: _blurTempRT
            _blurMaterial.SetVector("_BlurDirection", new Vector4(1, 0, 0, 0));
            cmd.Blit(sourceHandle, _blurTempRT, _blurMaterial, 0);
            
            // Pass 2: 垂直模糊
            // 输入: _blurTempRT (作为 _Soul_ScreenColor 传入)
            // 这里的技巧是：为了复用Shader逻辑，我们将 _Soul_ScreenColor 更新为 _blurTempRT
            cmd.SetGlobalTexture(_Soul_ScreenColor_ID, _blurTempRT);
            _blurMaterial.SetVector("_BlurDirection", new Vector4(0, 1, 0, 0));
            cmd.Blit(_blurTempRT, _blurredRT, _blurMaterial, 0);
            
            // Pass 3: Recombine
            // 输入1: 原始屏幕 (sourceHandle) -> 重新设置为 _Soul_ScreenColor
            // 输入2: 模糊结果 (_blurredRT) -> 通过 _SSSBlurredRT 传入
            cmd.SetGlobalTexture(_Soul_ScreenColor_ID, sourceHandle);
            _recombineMaterial.SetTexture(_SSSBlurredRT_ID, _blurredRT);
            _recombineMaterial.SetFloat("_DebugMode", (float)_settings.debugMode);
            
            cmd.Blit(sourceHandle, _finalRT, _recombineMaterial, 0);
            
            // Write Back
            cmd.Blit(_finalRT, sourceHandle);

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        private void SetupGlobalParameters(CommandBuffer cmd, CameraData cameraData, RenderTextureDescriptor desc)
        {
            cmd.SetGlobalTexture("_SSProfilesTexture", _settings.ssProfileTexture);
            // 传递纹理尺寸倒数，供采样使用
            cmd.SetGlobalVector("_SSProfilesTextureSize", new Vector4(
                _settings.ssProfileTexture.width, _settings.ssProfileTexture.height,
                1.0f / _settings.ssProfileTexture.width, 1.0f / _settings.ssProfileTexture.height
            ));
            
            float fov = cameraData.camera.fieldOfView * Mathf.Deg2Rad;
            float distanceToProjectionWindow = 1.0f / Mathf.Tan(fov * 0.5f);
            
            int kernelSize = 9;
            if (_settings.quality == 2) kernelSize = 13;
            else if (_settings.quality == 1) kernelSize = 9;
            else kernelSize = 6;
            
            cmd.SetGlobalVector("_SSSParams", new Vector4(
                _settings.sssScale * distanceToProjectionWindow / kernelSize * 0.5f,
                distanceToProjectionWindow,
                kernelSize,
                _settings.quality
            ));
            
            cmd.SetGlobalFloat("_DepthThreshold", _settings.depthThreshold);
        }

        public void Dispose()
        {
            _blurTempRT?.Release();
            _blurredRT?.Release();
            _finalRT?.Release();
            CoreUtils.Destroy(_blurMaterial);
            CoreUtils.Destroy(_recombineMaterial);
        }
    }
}
