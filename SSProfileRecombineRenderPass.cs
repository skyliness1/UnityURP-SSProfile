using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine. Rendering. Universal;

namespace SoulRender
{
    public class SSProfileRecombineRenderPass : ScriptableRenderPass
    {
        private const string PROFILER_TAG = "SSProfile Recombine";
        private ProfilingSampler _profilingSampler = new ProfilingSampler(PROFILER_TAG);

        private SSProfileRenderFeature.Settings _settings;
        private Material _recombineMaterial;
        
        private static readonly int s_SSSIntensityID = Shader.PropertyToID("_SSS_Intensity");

        public SSProfileRecombineRenderPass(SSProfileRenderFeature.Settings settings, Shader recombineShader)
        {
            _settings = settings;

            if (recombineShader != null)
            {
                _recombineMaterial = CoreUtils.CreateEngineMaterial(recombineShader);
                Debug.Log("[SSProfileRecombinePass] ✅ Recombine material created");
            }
            else
            {
                Debug.LogError("[SSProfileRecombinePass] Recombine shader is null!");
            }

            renderPassEvent = settings.renderPassEvent + 2; 
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0;
            desc.msaaSamples = 1;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_recombineMaterial == null)
            {
                Debug.LogWarning("[SSProfileRecombinePass] Recombine material is null, skipping");
                return;
            }

            CommandBuffer cmd = CommandBufferPool.Get(PROFILER_TAG);

            using (new ProfilingScope(cmd, _profilingSampler))
            {
                var cameraData = renderingData.cameraData;
                var cameraColorTarget = cameraData.renderer.cameraColorTargetHandle;
                
                _recombineMaterial.SetFloat(s_SSSIntensityID, _settings.sssIntensity);
                
                Blitter.BlitCameraTexture(cmd, cameraColorTarget, cameraColorTarget, _recombineMaterial, 0);
            }

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        public void Dispose()
        {
            CoreUtils.Destroy(_recombineMaterial);
        }
    }
}
