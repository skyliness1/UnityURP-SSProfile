#ifndef SSPROFILE_DEFINES_INCLUDED
#define SSPROFILE_DEFINES_INCLUDED

#include "Packages\com.unity.render-pipelines.universal@14.0.11\ShaderLibrary\SoulGBuffer.hlsl"

// ============================================================================
// 全局纹理 (由 Renderer Feature 设置)
// ============================================================================
TEXTURE2D(_SSProfilesTexture);
SAMPLER(sampler_SSProfilesTexture);
float4 _SSProfilesTextureSize; // (width, height, 1/width, 1/height)

SAMPLER(sampler_point_clamp);

// ============================================================================
// 纹理布局偏移量
// ============================================================================
#define SSSS_TINT_SCALE_OFFSET              0
#define BSSS_SURFACEALBEDO_OFFSET           1
#define BSSS_DMFP_OFFSET                    2
#define SSSS_TRANSMISSION_OFFSET            3
#define SSSS_BOUNDARY_COLOR_BLEED_OFFSET    4
#define SSSS_DUAL_SPECULAR_OFFSET           5
#define SSSS_KERNEL0_OFFSET                 6
#define SSSS_KERNEL0_SIZE                   13
#define SSSS_KERNEL1_OFFSET                 19
#define SSSS_KERNEL1_SIZE                   9
#define SSSS_KERNEL2_OFFSET                 28
#define SSSS_KERNEL2_SIZE                   6
#define BSSS_TRANSMISSION_PROFILE_OFFSET    34
#define BSSS_TRANSMISSION_PROFILE_SIZE      32

// ============================================================================
// 解码常量
// ============================================================================
#define DEC_UNIT_TO_WORLDUNITSCALE_IN_CM    50.0
#define DEC_UNIT_TO_DIFFUSEMEANFREEPATH_IN_MM 500.0
#define DEC_EXTINCTIONSCALE_FACTOR          100.0
#define SSSS_MAX_DUAL_SPECULAR_ROUGHNESS    2.0
#define SUBSURFACE_RADIUS_SCALE             1024.0
#define SSSS_MAX_TRANSMISSION_PROFILE_DISTANCE 5.0
#define TABLE_MAX_RGB                       1.0
#define TABLE_MAX_A                         3.0
#define BURLEY_CM_2_MM                      10.0
#define BURLEY_MM_2_CM                      0.1

// 判断是否是 SSS 材质
bool IsSubsurfaceProfileShadingModel(uint shadingModelID)
{
    return shadingModelID == SHADINGMODELID_SUBSURFACE_PROFILE;
}

// 从 GBufferD 提取 SSS 数据
void ExtractSSSDataFromGBuffer(GBufferData gbuffer, out uint profileId, out float opacity)
{
    profileId = (uint)(gbuffer.customDataSingle * 255.0 + 0.5);
    opacity = gbuffer.metallic; // 复用 metallic 通道存储 opacity
}

#endif