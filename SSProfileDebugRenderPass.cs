using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace SoulRender
{
    public class SSProfileDebugRenderPass : ScriptableRenderPass
    {
        private const string PROFILER_TAG = "SSProfile Debug View";
        private ProfilingSampler _profilingSampler = new ProfilingSampler(PROFILER_TAG);

        private SSProfileRenderFeature.Settings _settings;
        private Material _debugMaterial;

        private static readonly int s_DebugModeID = Shader.PropertyToID("_DebugMode");

        public SSProfileDebugRenderPass(SSProfileRenderFeature.Settings settings)
        {
            _settings = settings;

            // 创建 Debug Material
            Shader debugShader = Shader.Find("Hidden/SSProfile/DebugView");
            if (debugShader != null)
            {
                _debugMaterial = new Material(debugShader);
            }
            else
            {
                Debug. LogError("[SSProfileDebugPass] Debug shader 'Hidden/SSProfile/DebugView' not found!");
            }

            renderPassEvent = settings.renderPassEvent + 3;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_debugMaterial == null)
            {
                return;
            }
            
            CommandBuffer cmd = CommandBufferPool.Get(PROFILER_TAG);

            using (new ProfilingScope(cmd, _profilingSampler))
            {
                var cameraData = renderingData. cameraData;
                var source = cameraData.renderer.cameraColorTargetHandle;

                // 设置 Debug 模式
                _debugMaterial.SetInt(s_DebugModeID, (int)_settings.debugMode);

                // 绑定 Setup 输出纹理
                _debugMaterial.SetTexture("_SSProfileSetupDiffuse", Shader.GetGlobalTexture("_SSProfileSetupDiffuse"));
                _debugMaterial.SetTexture("_SSProfileSetupSpecular", Shader.GetGlobalTexture("_SSProfileSetupSpecular"));
                _debugMaterial.SetTexture("_SSProfileScatteredDiffuse", Shader.GetGlobalTexture("_SSProfileScatteredDiffuse"));

                // 全屏 Blit（替换 CameraColor）
                Blitter.BlitCameraTexture(cmd, source, source, _debugMaterial, 0);
            }

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }
        public void Dispose()
        {
            if (_debugMaterial != null)
            {
                Object.DestroyImmediate(_debugMaterial);
            }
        }
    }
}
