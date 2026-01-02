#ifndef SOUL_BURLEY_NORMALIZED_SSS_INCLUDE
#define SOUL_BURLEY_NORMALIZED_SSS_INCLUDE

// ============================================================================
// Burley 缩放因子（与 C# 端一致）
// ============================================================================

float GetSearchLightDiffuseScalingFactor(float surfaceAlbedo)
{
    float delta = surfaceAlbedo - 0.33;
    return 3.5 + 100.0 * delta * delta * delta * delta;
}

float3 GetSearchLightDiffuseScalingFactor3D(float3 surfaceAlbedo)
{
    return float3(
        GetSearchLightDiffuseScalingFactor(surfaceAlbedo.r),
        GetSearchLightDiffuseScalingFactor(surfaceAlbedo.g),
        GetSearchLightDiffuseScalingFactor(surfaceAlbedo.b)
    );
}

float GetPerpendicularScalingFactor(float surfaceAlbedo)
{
    return 1.85 - surfaceAlbedo + 7.0 * pow(abs(surfaceAlbedo - 0.8), 3.0);
}

float3 GetPerpendicularScalingFactor3D(float3 surfaceAlbedo)
{
    return float3(
        GetPerpendicularScalingFactor(surfaceAlbedo.r),
        GetPerpendicularScalingFactor(surfaceAlbedo.g),
        GetPerpendicularScalingFactor(surfaceAlbedo.b)
    );
}

// ============================================================================
// Burley 散射轮廓
// ============================================================================

#define INV_8PI 0.039788735772973833942220940843129

float BurleyProfile(float r, float A, float S, float L)
{
    if (S <= 1e-6 || L <= 1e-6)
        return 0.0;
    
    float D = 1.0 / S;
    float R = r / L;
    float negRbyD = -R / D;
    
    return A * max(
        (exp(negRbyD) + exp(negRbyD / 3.0)) / (D * L) * INV_8PI,
        0.0
    );
}

float3 BurleyProfile3D(float r, float3 A, float3 S, float3 L)
{
    return float3(
        BurleyProfile(r, A.r, S.r, L.r),
        BurleyProfile(r, A.g, S.g, L.g),
        BurleyProfile(r, A.b, S.b, L.b)
    );
}

// ============================================================================
// Burley 传输轮廓
// ============================================================================

float BurleyTransmission(float r, float A, float S, float L)
{
    if (L <= 1e-6)
        return 0.0;
    
    return 0.25 * A * (exp(-S * r / L) + 3.0 * exp(-S * r / (3.0 * L)));
}

float3 BurleyTransmission3D(float r, float3 A, float3 S, float3 L)
{
    return float3(
        BurleyTransmission(r, A.r, S.r, L.r),
        BurleyTransmission(r, A.g, S.g, L.g),
        BurleyTransmission(r, A.b, S.b, L.b)
    );
}

#endif