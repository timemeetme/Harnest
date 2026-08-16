/**
 * Theme — DSH 移动端视觉常量。
 * 对标 deepseek-harness Web GUI 深色风格，同时提供浅色 fallback。
 */

export namespace Theme {
  export namespace Dark {
    export const background: string = '#1a1a2e';
    export const surface: string = '#252540';
    export const surfaceElevated: string = '#2d2d50';
    export const divider: string = '#3a3a5c';
    export const primary: string = '#00d4aa';
    export const primaryOn: string = '#1a1a2e';
    export const accent: string = '#7c5cff';
    export const success: string = '#4CAF50';
    export const warning: string = '#FFA726';
    export const error: string = '#EF5350';
    export const textPrimary: string = '#f2f2f7';
    export const textSecondary: string = '#a0a0b8';
    export const textHint: string = '#6c6c88';
    export const userBubble: string = '#1f3a4a';
    export const assistantBubble: string = '#2d2d50';
  }

  export namespace Light {
    export const background: string = '#f7f7fb';
    export const surface: string = '#ffffff';
    export const surfaceElevated: string = '#ffffff';
    export const divider: string = '#e4e4ee';
    export const primary: string = '#00b894';
    export const primaryOn: string = '#ffffff';
    export const accent: string = '#6c4ce0';
    export const success: string = '#2E7D32';
    export const warning: string = '#E65100';
    export const error: string = '#C62828';
    export const textPrimary: string = '#1a1a2e';
    export const textSecondary: string = '#5a5a7a';
    export const textHint: string = '#9c9cb4';
    export const userBubble: string = '#e3f7f0';
    export const assistantBubble: string = '#ffffff';
  }
}

export function activeTheme(useDark: boolean) {
  return useDark ? Theme.Dark : Theme.Light;
}
