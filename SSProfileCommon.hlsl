#ifndef SOUL_SSPROFILE_COMMON_INCLUDE
#define SOUL_SSPROFILE_COMMON_INCLUDE

// ============================================================================
// 常量定义（与 C# 端保持一致）
// ============================================================================

#define SSSS_TINT_SCALE_OFFSET                 0
#define BSSS_SURFACEALBEDO_OFFSET              1
#define BSSS_DMFP_OFFSET                       2
#define SSSS_TRANSMISSION_OFFSET               3
#define SSSS_BOUNDARY_COLOR_BLEED_OFFSET       4
#define SSSS_DUAL_SPECULAR_OFFSET              5
#define SSSS_KERNEL0_OFFSET                    6
#define SSSS_KERNEL0_SIZE                      13
#define SSSS_KERNEL1_OFFSET                    19
#define SSSS_KERNEL1_SIZE                      9
#define SSSS_KERNEL2_OFFSET                    28
#define SSSS_KERNEL2_SIZE                      6
#define BSSS_TRANSMISSION_PROFILE_OFFSET       34
#define BSSS_TRANSMISSION_PROFILE_SIZE         32

// 解码常量
#define DEC_WORLDUNITSCALE_IN_CM               50.0
#define DEC_DMFP_IN_MM                         500.0
#define DEC_EXTINCTIONSCALE                    100.0
#define SSSS_MAX_DUAL_SPECULAR_ROUGHNESS       2.0

#define SUBSURFACE_RADIUS_SCALE                1024.0
#define SUBSURFACE_KERNEL_SIZE                 3.0

// ============================================================================
// 解码函数
// ============================================================================

float DecodeWorldUnitScale(float encoded)
{
    return encoded * DEC_WORLDUNITSCALE_IN_CM;
}

float3 DecodeDiffuseMeanFreePath(float3 encoded)
{
    return encoded * DEC_DMFP_IN_MM;
}

float DecodeExtinctionScale(float encoded)
{
    return encoded * DEC_EXTINCTIONSCALE;
}

float DecodeScatteringDistribution(float encoded)
{
    return encoded * 2.0 - 1.0;
}

//双精度版本（用于 roughness0 和 roughness1）
float2 DecodeDualSpecularRoughness(float2 encoded)
{
    return encoded * SSSS_MAX_DUAL_SPECULAR_ROUGHNESS;
}

//单精度版本（用于 avgRoughness）
float DecodeSingleRoughness(float encoded)
{
    return encoded * SSSS_MAX_DUAL_SPECULAR_ROUGHNESS;
}

#define TABLE_MAX_A 3.0

float DecodeKernelOffset(float encodedAlpha, float scatterRadiusInMm)
{
    float normalizedOffset = encodedAlpha * TABLE_MAX_A;
    return normalizedOffset * (scatterRadiusInMm / SUBSURFACE_RADIUS_SCALE);
}

// ============================================================================
// Profile ID 编解码
// ============================================================================

uint ExtractProfileID(float encodedID)
{
    return uint(encodedID * 255.0 + 0.5);
}

float EncodeProfileID(uint profileID)
{
    return float(profileID) / 255.0;
}

#endif