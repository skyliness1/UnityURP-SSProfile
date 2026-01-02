using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace SoulRender
{
    public class SSProfileSetupRenderPass : ScriptableRenderPass
    {
        private const string PROFILER_TAG = "SSProfile Setup (Compute)";
        private ProfilingSampler _profilingSampler = new ProfilingSampler(PROFILER_TAG);

        private SSProfileRenderFeature. Settings _settings;
        private ComputeShader _setupCS;
        private int _setupKernel;

        // 输出纹理
        private RTHandle _setupDiffuse;
        private RTHandle _setupSpecular;

        // Tile 分类缓冲区
        private ComputeBuffer _tileBuffer;
        private ComputeBuffer _tileCountBuffer;
        
        public ComputeBuffer TileBuffer => _tileBuffer;
        public ComputeBuffer TileCountBuffer => _tileCountBuffer;

        private const int TILE_SIZE = 8;
        private const int MAX_TILES = 16384;

        // 全局纹理 ID
        private static readonly int s_SetupDiffuseID = Shader.PropertyToID("_SSProfileSetupDiffuse");
        private static readonly int s_SetupSpecularID = Shader.PropertyToID("_SSProfileSetupSpecular");
        private static readonly int s_TileBufferID = Shader.PropertyToID("_SSProfileTileBuffer");
        private static readonly int s_TileCountBufferID = Shader.PropertyToID("_SSProfileTileCountBuffer");

        public SSProfileSetupRenderPass(SSProfileRenderFeature.Settings settings)
        {
            _settings = settings;
            _setupCS = settings.setupCS;

            // 查找 Kernel
            if (_setupCS.HasKernel("CSSetup"))
            {
                _setupKernel = _setupCS.FindKernel("CSSetup");
                Debug.Log($"[SSProfileSetupPass] Found kernel 'CSSetup' at index {_setupKernel}");
            }
            else
            {
                Debug.LogError("[SSProfileSetupPass] Kernel 'CSSetup' not found in Compute Shader!");
            }

            renderPassEvent = settings.renderPassEvent;

            // 创建 Tile Buffers
            _tileBuffer = new ComputeBuffer(MAX_TILES, sizeof(uint) * 2, ComputeBufferType.Append);
            _tileCountBuffer = new ComputeBuffer(1, sizeof(uint), ComputeBufferType.Raw);

            Debug.Log($"[SSProfileSetupPass] Created with TILE_SIZE={TILE_SIZE}, MAX_TILES={MAX_TILES}");
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0;
            desc.enableRandomWrite = true;
            desc.colorFormat = RenderTextureFormat.ARGBHalf;
            desc.msaaSamples = 1;

            int originalWidth = desc.width;
            int originalHeight = desc.height;

            if (_settings.useHalfResolution)
            {
                desc. width /= 2;
                desc. height /= 2;
            }

            RenderingUtils.ReAllocateIfNeeded(
                ref _setupDiffuse,
                desc,
                FilterMode.Bilinear,
                TextureWrapMode.Clamp,
                name: "_SSProfileSetupDiffuse"
            );

            RenderingUtils.ReAllocateIfNeeded(
                ref _setupSpecular,
                desc,
                FilterMode.Bilinear,
                TextureWrapMode.Clamp,
                name:  "_SSProfileSetupSpecular"
            );

            Debug.Log($"[SSProfileSetupPass] Setup textures: {desc.width}x{desc.height} (original: {originalWidth}x{originalHeight})");
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_setupCS == null)
            {
                Debug.LogWarning("[SSProfileSetupPass] Setup CS is null, skipping");
                return;
            }

            CommandBuffer cmd = CommandBufferPool.Get(PROFILER_TAG);

            using (new ProfilingScope(cmd, _profilingSampler))
            {
                var camera = renderingData.cameraData.camera;
                Matrix4x4 viewMatrix = camera.worldToCameraMatrix;
                Matrix4x4 projMatrix = GL.GetGPUProjectionMatrix(camera.projectionMatrix, renderingData.cameraData.IsCameraProjectionMatrixFlipped());
                Matrix4x4 viewProjMatrix = projMatrix * viewMatrix;
                Matrix4x4 invViewProjMatrix = viewProjMatrix.inverse;

                // 传递给 Compute Shader
                cmd.SetComputeMatrixParam(_setupCS, "_InvViewProjectionMatrix", invViewProjMatrix);
                
                
                // ============================================================
                // 1. 重置 Tile 计数
                // ============================================================

                cmd.SetBufferCounterValue(_tileBuffer, 0);

                uint[] zeroData = new uint[] { 0 };
                cmd.SetBufferData(_tileCountBuffer, zeroData);

                // ============================================================
                // 2. 绑定输出纹理
                // ============================================================

                cmd.SetComputeTextureParam(_setupCS, _setupKernel, "_SetupDiffuseOutput", _setupDiffuse);
                cmd.SetComputeTextureParam(_setupCS, _setupKernel, "_SetupSpecularOutput", _setupSpecular);

                // ============================================================
                // 3. 绑定 Tile Buffers
                // ============================================================

                cmd.SetComputeBufferParam(_setupCS, _setupKernel, "_TileBuffer", _tileBuffer);
                cmd.SetComputeBufferParam(_setupCS, _setupKernel, "_TileCountBuffer", _tileCountBuffer);

                // ============================================================
                // 4. 设置参数
                // ============================================================

                int width = _setupDiffuse.rt.width;
                int height = _setupDiffuse.rt.height;

                cmd.SetComputeVectorParam(_setupCS, "_SetupTexture_TexelSize", new Vector4(
                    width,
                    height,
                    1.0f / width,
                    1.0f / height
                ));

                // ============================================================
                // 5.  Dispatch Compute Shader
                // ============================================================

                int threadGroupsX = (width + TILE_SIZE - 1) / TILE_SIZE;
                int threadGroupsY = (height + TILE_SIZE - 1) / TILE_SIZE;

                Debug.Log($"[SSProfileSetupPass] Dispatching {threadGroupsX}x{threadGroupsY} thread groups for {width}x{height} texture");

                cmd.DispatchCompute(_setupCS, _setupKernel, threadGroupsX, threadGroupsY, 1);

                // ============================================================
                // 6. 设置全局纹理和 Buffer
                // ============================================================

                cmd.SetGlobalTexture(s_SetupDiffuseID, _setupDiffuse);
                cmd.SetGlobalTexture(s_SetupSpecularID, _setupSpecular);
                cmd.SetGlobalBuffer(s_TileBufferID, _tileBuffer);
                cmd.SetGlobalBuffer(s_TileCountBufferID, _tileCountBuffer);

                // ============================================================
                // 7. 读取 Tile 计数（调试用）
                // ============================================================

                #if UNITY_EDITOR
                // 注意：这会引入 GPU->CPU 同步，仅用于调试
                ComputeBuffer.CopyCount(_tileBuffer, _tileCountBuffer, 0);
                
                uint[] tileCount = new uint[1];
                _tileCountBuffer.GetData(tileCount);
                
                Debug.Log($"[SSProfileSetupPass] Detected {tileCount[0]} tiles with SSS pixels (max: {MAX_TILES})");
                #endif
            }

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        public void Dispose()
        {
            _setupDiffuse?.Release();
            _setupSpecular?.Release();
            _tileBuffer?.Release();
            _tileCountBuffer?.Release();

            Debug.Log("[SSProfileSetupPass] Disposed");
        }
    }
}
