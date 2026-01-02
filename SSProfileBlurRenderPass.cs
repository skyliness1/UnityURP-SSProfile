using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering. Universal;

namespace SoulRender
{
    public class SSProfileBlurRenderPass : ScriptableRenderPass
    {
        private const string PROFILER_TAG = "SSProfile Blur";
        private ProfilingSampler _profilingSampler = new ProfilingSampler(PROFILER_TAG);

        private SSProfileRenderFeature. Settings _settings;
        private ComputeShader _blurCS;
        private SSProfileSetupRenderPass _setupPass;
        
        private ComputeShader _prepareArgsCS;
        private int _prepareArgsKernel;

        private int _blurHorizontalKernel;
        private int _blurVerticalKernel;
        private int _blurHorizontalIndirectKernel;
        private int _blurVerticalIndirectKernel;

        private RTHandle _blurTemp;
        private RTHandle _scatteredDiffuse;
        private ComputeBuffer _indirectArgsBuffer;

        private const int TILE_SIZE = 8;

        private static readonly int s_BlurInputTextureID = Shader.PropertyToID("_BlurInputTexture");
        private static readonly int s_BlurOutputTextureID = Shader.PropertyToID("_BlurOutputTexture");
        private static readonly int s_BlurTextureSizeID = Shader.PropertyToID("_BlurTexture_TexelSize");
        private static readonly int s_BlurIntensityID = Shader.PropertyToID("_BlurIntensity");
        private static readonly int s_DepthScaleID = Shader.PropertyToID("_DepthScale");
        private static readonly int s_ScatteredDiffuseID = Shader.PropertyToID("_SSProfileScatteredDiffuse");
        private static readonly int s_TileBufferID = Shader.PropertyToID("_SSProfileTileBuffer");

        public SSProfileBlurRenderPass(
            SSProfileRenderFeature. Settings settings, 
            ComputeShader blurCS,
            SSProfileSetupRenderPass setupPass,
            ComputeShader indirectArgsCS)  
        {
            _settings = settings;
            _blurCS = blurCS;
            _setupPass = setupPass;
            _prepareArgsCS = indirectArgsCS; 

            if (_blurCS != null)
            {
                _blurHorizontalKernel = _blurCS.FindKernel("CSBlurHorizontal");
                _blurVerticalKernel = _blurCS.FindKernel("CSBlurVertical");

                if (_blurCS.HasKernel("CSBlurHorizontalIndirect") && _blurCS.HasKernel("CSBlurVerticalIndirect"))
                {
                    _blurHorizontalIndirectKernel = _blurCS.FindKernel("CSBlurHorizontalIndirect");
                    _blurVerticalIndirectKernel = _blurCS.FindKernel("CSBlurVerticalIndirect");
                    Debug.Log("[SSProfileBlurPass] ✅ Indirect Dispatch kernels found");
                }
                else
                {
                    _blurHorizontalIndirectKernel = -1;
                }
            }
            
            if (_prepareArgsCS != null)
            {
                if (_prepareArgsCS.HasKernel("CSPrepareIndirectArgs"))
                {
                    _prepareArgsKernel = _prepareArgsCS.FindKernel("CSPrepareIndirectArgs");
                    Debug.Log($"[SSProfileBlurPass] IndirectArgs CS loaded: {_prepareArgsCS.name}");
                }
                else
                {
                    Debug.LogError("[SSProfileBlurPass] Kernel 'CSPrepareIndirectArgs' not found in IndirectArgs CS!");
                    _prepareArgsCS = null;
                }
            }
            else
            {
                Debug.LogWarning("[SSProfileBlurPass] IndirectArgs CS not assigned.  Indirect Dispatch will use CPU sync fallback.");
            }

            _indirectArgsBuffer = new ComputeBuffer(3, sizeof(uint), ComputeBufferType.IndirectArguments);
            renderPassEvent = settings.renderPassEvent + 1;
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0;
            desc.enableRandomWrite = true;
            desc. colorFormat = RenderTextureFormat.ARGBHalf;
            desc.msaaSamples = 1;

            if (_settings.useHalfResolution)
            {
                desc.width /= 2;
                desc. height /= 2;
            }

            RenderingUtils.ReAllocateIfNeeded(ref _blurTemp, desc, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_SSProfileBlurTemp");
            RenderingUtils.ReAllocateIfNeeded(ref _scatteredDiffuse, desc, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_SSProfileScatteredDiffuse");
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_blurCS == null)
                return;

            CommandBuffer cmd = CommandBufferPool. Get(PROFILER_TAG);

            using (new ProfilingScope(cmd, _profilingSampler))
            {
                int width = _blurTemp. rt.width;
                int height = _blurTemp.rt. height;
                Vector4 texelSize = new Vector4(width, height, 1.0f / width, 1.0f / height);
                
                cmd.SetRenderTarget(_blurTemp.nameID, 0, CubemapFace.Unknown, -1);
                cmd.ClearRenderTarget(false, true, Color.clear);

                cmd.SetRenderTarget(_scatteredDiffuse.nameID, 0, CubemapFace.Unknown, -1);
                cmd.ClearRenderTarget(false, true, Color.clear);

                cmd.SetComputeVectorParam(_blurCS, s_BlurTextureSizeID, texelSize);
                cmd.SetComputeFloatParam(_blurCS, s_BlurIntensityID, _settings.sssIntensity);
                cmd.SetComputeFloatParam(_blurCS, s_DepthScaleID, 100.0f);

                if (_settings. useIndirectDispatch && _blurHorizontalIndirectKernel >= 0)
                {
                    ExecuteIndirectDispatch(cmd);
                }
                else
                {
                    ExecuteTraditionalDispatch(cmd, width, height);
                }
                
                cmd.SetGlobalTexture(s_ScatteredDiffuseID, _scatteredDiffuse.nameID);
                
#if UNITY_EDITOR
                Debug.Log($"[SSProfileBlurPass] Set global texture: _SSProfileScatteredDiffuse = {_scatteredDiffuse.name}");
#endif
            }

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        private void ExecuteTraditionalDispatch(CommandBuffer cmd, int width, int height)
        {
            int threadGroupsX = (width + TILE_SIZE - 1) / TILE_SIZE;
            int threadGroupsY = (height + TILE_SIZE - 1) / TILE_SIZE;

            cmd.BeginSample("Horizontal Blur (Traditional)");
            cmd.SetComputeTextureParam(_blurCS, _blurHorizontalKernel, s_BlurOutputTextureID, _blurTemp);
            cmd.DispatchCompute(_blurCS, _blurHorizontalKernel, threadGroupsX, threadGroupsY, 1);
            cmd.EndSample("Horizontal Blur (Traditional)");

            cmd.BeginSample("Vertical Blur (Traditional)");
            cmd.SetComputeTextureParam(_blurCS, _blurVerticalKernel, s_BlurInputTextureID, _blurTemp);
            cmd.SetComputeTextureParam(_blurCS, _blurVerticalKernel, s_BlurOutputTextureID, _scatteredDiffuse);
            cmd.DispatchCompute(_blurCS, _blurVerticalKernel, threadGroupsX, threadGroupsY, 1);
            cmd.EndSample("Vertical Blur (Traditional)");
        }

        private void ExecuteIndirectDispatch(CommandBuffer cmd)
        {
            var tileBuffer = _setupPass.TileBuffer;
            var tileCountBuffer = _setupPass.TileCountBuffer;

            if (tileBuffer == null || tileCountBuffer == null)
            {
                Debug.LogWarning("[SSProfileBlurPass] TileBuffer not available, fallback to traditional");
                ExecuteTraditionalDispatch(cmd, _blurTemp.rt.width, _blurTemp.rt.height);
                return;
            }

            // 复制 AppendBuffer 计数器
            ComputeBuffer. CopyCount((ComputeBuffer)tileBuffer, (ComputeBuffer)tileCountBuffer, 0);
            
            if (_prepareArgsCS != null)
            {
                cmd.BeginSample("Prepare Indirect Args");
                cmd.SetComputeBufferParam(_prepareArgsCS, _prepareArgsKernel, "_TileCountBuffer", (ComputeBuffer)tileCountBuffer);
                cmd.SetComputeBufferParam(_prepareArgsCS, _prepareArgsKernel, "_IndirectArgsBuffer", _indirectArgsBuffer);
                cmd.DispatchCompute(_prepareArgsCS, _prepareArgsKernel, 1, 1, 1);
                cmd.EndSample("Prepare Indirect Args");
            }
            else
            {
#if UNITY_EDITOR
                Debug.LogWarning("[SSProfileBlurPass] Using CPU sync fallback (performance impact!)");
#endif

                uint[] tileCount = new uint[1];
                tileCountBuffer.GetData(tileCount);

                if (tileCount[0] == 0)
                {
                    Debug. LogWarning("[SSProfileBlurPass] No SSS tiles detected");
                    return;
                }

                uint[] indirectArgs = new uint[] { tileCount[0], 1, 1 };
                _indirectArgsBuffer.SetData(indirectArgs);
            }

            // 绑定 TileBuffer
            cmd.SetComputeBufferParam(_blurCS, _blurHorizontalIndirectKernel, s_TileBufferID, (ComputeBuffer)tileBuffer);
            cmd.SetComputeBufferParam(_blurCS, _blurVerticalIndirectKernel, s_TileBufferID, (ComputeBuffer)tileBuffer);

            // Horizontal Blur (Indirect)
            cmd.BeginSample("Horizontal Blur (Indirect)");
            cmd.SetComputeTextureParam(_blurCS, _blurHorizontalIndirectKernel, s_BlurOutputTextureID, _blurTemp);
            cmd.DispatchCompute(_blurCS, _blurHorizontalIndirectKernel, _indirectArgsBuffer, 0u);
            cmd.EndSample("Horizontal Blur (Indirect)");

            // Vertical Blur (Indirect)
            cmd.BeginSample("Vertical Blur (Indirect)");
            cmd.SetComputeTextureParam(_blurCS, _blurVerticalIndirectKernel, s_BlurInputTextureID, _blurTemp);
            cmd.SetComputeTextureParam(_blurCS, _blurVerticalIndirectKernel, s_BlurOutputTextureID, _scatteredDiffuse);
            cmd.DispatchCompute(_blurCS, _blurVerticalIndirectKernel, _indirectArgsBuffer, 0u);
            cmd.EndSample("Vertical Blur (Indirect)");
        }

        public void Dispose()
        {
            _blurTemp?.Release();
            _scatteredDiffuse?.Release();
            _indirectArgsBuffer?.Release();
        }
    }
}
