import { display } from '@kit.ArkUI';

// 全局 px2vp 已废弃，统一走 display 密度换算（见 docs/鸿蒙App开发指南.md）
export function pxToVp(px: number): number {
  try {
    const d = display.getDefaultDisplaySync();
    const density = d.densityPixels > 0 ? d.densityPixels : 3;
    return px / density;
  } catch (err) {
    return px / 3;
  }
}
