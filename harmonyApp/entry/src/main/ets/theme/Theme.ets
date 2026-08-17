export class ThemeColors {
  background: string = '';
  surface: string = '';
  surfaceElevated: string = '';
  divider: string = '';
  primary: string = '';
  primaryOn: string = '';
  accent: string = '';
  success: string = '';
  warning: string = '';
  error: string = '';
  textPrimary: string = '';
  textSecondary: string = '';
  textHint: string = '';
  userBubble: string = '';
  assistantBubble: string = '';
}

export const darkTheme: ThemeColors = {
  background: '#1a1a2e',
  surface: '#252540',
  surfaceElevated: '#2d2d50',
  divider: '#3a3a5c',
  primary: '#00d4aa',
  primaryOn: '#1a1a2e',
  accent: '#7c5cff',
  success: '#4CAF50',
  warning: '#FFA726',
  error: '#EF5350',
  textPrimary: '#f2f2f7',
  textSecondary: '#a0a0b8',
  textHint: '#6c6c88',
  userBubble: '#1f3a4a',
  assistantBubble: '#2d2d50',
};

export const lightTheme: ThemeColors = {
  background: '#f7f7fb',
  surface: '#ffffff',
  surfaceElevated: '#ffffff',
  divider: '#e4e4ee',
  primary: '#00b894',
  primaryOn: '#ffffff',
  accent: '#6c4ce0',
  success: '#2E7D32',
  warning: '#E65100',
  error: '#C62828',
  textPrimary: '#1a1a2e',
  textSecondary: '#5a5a7a',
  textHint: '#9c9cb4',
  userBubble: '#e3f7f0',
  assistantBubble: '#ffffff',
};

export function activeTheme(useDark: boolean): ThemeColors {
  return useDark ? darkTheme : lightTheme;
}
