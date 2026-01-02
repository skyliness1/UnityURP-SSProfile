using System.Collections;
using System.Collections.Generic;
using UnityEngine;

namespace SoulRender
{
    public static class SSProfileUpgrader
    {
        /// <summary>
        /// 验证并修正参数（仅 Burley 路径）
        /// </summary>
        public static bool ValidateAndFix(SSProfileSettings settings)
        {
            bool isFixed = false;
        
            // 修正 1: MFP Distance 不能为 0
            if (settings.meanFreePathDistance < 0.1f)
            {
                Debug.LogWarning($"[SSProfileUpgrader] '{settings.name}' MFP Distance too small, clamping to 0.1");
                settings.meanFreePathDistance = 0.1f;
                isFixed = true;
            }
        
            // 修正 2: MFP Color 不能全为 0
            if (settings.meanFreePathColor.r < 0.001f && 
                settings.meanFreePathColor.g < 0.001f && 
                settings.meanFreePathColor.b < 0.001f)
            {
                Debug.LogWarning($"[SSProfileUpgrader] '{settings.name}' MFP Color too dark, resetting to default");
                settings.meanFreePathColor = new Color(1.0f, 0f, 0.5f, 0.4f);
                isFixed = true;
            }
        
            // 修正 3: Surface Albedo 限制在 [0.01, 1.0]
            settings.surfaceAlbedo = new Color(
                Mathf.Clamp(settings.surfaceAlbedo.r, 0.01f, 1.0f),
                Mathf.Clamp(settings.surfaceAlbedo.g, 0.01f, 1.0f),
                Mathf.Clamp(settings.surfaceAlbedo.b, 0.01f, 1.0f),
                1.0f
            );
        
            if (isFixed)
            {
                UnityEditor.EditorUtility.SetDirty(settings);
            }
        
            return isFixed;
        }
    }
}


