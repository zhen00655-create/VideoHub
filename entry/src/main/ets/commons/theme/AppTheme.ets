/**
 * 双主题色板：白天（亮堂）/ 黑夜（原来的深靛蓝夜空）。
 *
 * ⚠️⚠️ 为什么用 getter 而不是拆成两套常量：
 *    全工程有 **364 处** `AppTheme.XXX` 引用。如果改成 `AppThemeDark.XXX` / `AppThemeLight.XXX`，
 *    每一处都要跟着改，还得在每个页面里写「当前用哪套」的三元判断。
 *    现在把颜色全部做成 `static get`，内部按 `themeMode` 取色板 ——
 *    **调用点一行都不用动**，切换主题只需 `AppTheme.setMode(mode)` 一次。
 *
 * ⚠️ 切换主题后界面不会自动重绘：getter 不是响应式的。
 *    `setMode()` 会把自增的 `themeVersion` 写进 AppStorage，
 *    页面根节点订阅 `@StorageProp('themeVersion')` 才能触发重渲染（见 SettingPage 的主题切换）。
 *
 * ⚠️ 播放器/详情页**不参与主题切换**：它们底色是黑（`VIDEO_BG`），
 *    两个色板里都保持 `#000000`，这样白天模式下看视频仍是黑底，不影响画面色彩判断。
 */
export enum ThemeMode {
  /** 黑夜（默认，沿用最早的深靛蓝夜空渐变） */
  Dark = 0,
  /** 白天（参考用户给的示意图：淡蓝 → 淡紫 → 暖粉的柔和渐变，白卡片） */
  Light = 1
}

/** 一套完整的颜色定义。字段名与旧版 AppTheme 的静态成员一一对应。 */
interface ThemePalette {
  BG: string;
  BG_GRAD_TOP: string;
  BG_GRAD_MID: string;
  BG_GRAD_BOTTOM: string;
  PANEL_GRAD_TOP: string;
  PANEL_GRAD_BOTTOM: string;
  CARD: string;
  CARD_PRESSED: string;
  SURFACE: string;
  LINE: string;
  TEXT_PRIMARY: string;
  TEXT_SECONDARY: string;
  TEXT_TERTIARY: string;
  ACCENT: string;
  ACCENT_SOFT: string;
  GOLD: string;
  PLACEHOLDER: string;
  EP_DONE_BG: string;
  EP_DONE_TEXT: string;
  BADGE_BG: string;
  VIDEO_BG: string;
  /** 底部页签栏背景。原来是写死在 Index.ets 里的 '#161B33'，白天模式下不会跟着变 */
  TAB_BAR_BG: string;
}

/** 黑夜色板：深靛蓝夜空（原样保留，一个色值都没动） */
const DARK_PALETTE: ThemePalette = {
  BG: '#0B0E1A',
  BG_GRAD_TOP: '#1E2547',
  BG_GRAD_MID: '#141A31',
  BG_GRAD_BOTTOM: '#0A0D18',
  PANEL_GRAD_TOP: '#232B4D',
  PANEL_GRAD_BOTTOM: '#171D33',
  CARD: '#1A2036',
  CARD_PRESSED: '#242B44',
  SURFACE: '#1F2540',
  LINE: '#2B3350',
  TEXT_PRIMARY: '#F2F4F8',
  TEXT_SECONDARY: '#9BA3B4',
  TEXT_TERTIARY: '#6B7280',
  ACCENT: '#FF4D4F',
  ACCENT_SOFT: 'rgba(255,77,79,0.16)',
  GOLD: '#FFC53D',
  PLACEHOLDER: '#1B2033',
  EP_DONE_BG: '#141829',
  EP_DONE_TEXT: '#59616F',
  BADGE_BG: 'rgba(0,0,0,0.62)',
  VIDEO_BG: '#000000',
  TAB_BAR_BG: '#161B33'
};

/**
 * 白天色板。
 * 背景三段取自用户示意图的观感：顶部淡蓝、中部淡紫灰、底部暖粉，整体亮堂但不刺眼；
 * 卡片用纯白（亮堂感的主要来源），文字换成深灰而非纯黑（长时间看不累）。
 * 金色刻意加深一档（#D9930D）：原来的 #FFC53D 在白底上对比度不够，评分数字会糊。
 */
const LIGHT_PALETTE: ThemePalette = {
  BG: '#ECEBF3',
  BG_GRAD_TOP: '#DCE8F5',
  BG_GRAD_MID: '#EBE7F1',
  BG_GRAD_BOTTOM: '#F7DFE3',
  PANEL_GRAD_TOP: '#FFFFFF',
  PANEL_GRAD_BOTTOM: '#F3F0F8',
  CARD: '#FFFFFF',
  CARD_PRESSED: '#EFEBF4',
  SURFACE: '#FFFFFF',
  LINE: '#E3DEE9',
  TEXT_PRIMARY: '#1C1E28',
  TEXT_SECONDARY: '#5C6172',
  TEXT_TERTIARY: '#8C91A0',
  ACCENT: '#FF4D4F',
  ACCENT_SOFT: 'rgba(255,77,79,0.12)',
  GOLD: '#D9930D',
  PLACEHOLDER: '#EDEAF3',
  EP_DONE_BG: '#F1EFF5',
  EP_DONE_TEXT: '#A2A7B4',
  BADGE_BG: 'rgba(0,0,0,0.58)',
  VIDEO_BG: '#000000',
  // 白天用近白微暖，和底部的 #F7DFE3 暖粉渐变接得上，不会一块死白跳出来
  TAB_BAR_BG: '#FDFBFC'
};

export class AppTheme {
  /** 当前主题，默认黑夜（首帧先按这个渲染，设置读完再校正） */
  private static themeMode: number = ThemeMode.Dark;

  /**
   * 当前生效的色板。
   * 写成**方法**而不是 `static get`：ArkTS 对私有静态 getter 的支持不如普通静态方法稳，
   * 而每个颜色 getter 都要调它，没必要在这里冒险。
   */
  private static cur(): ThemePalette {
    return AppTheme.themeMode === ThemeMode.Light ? LIGHT_PALETTE : DARK_PALETTE;
  }

  /** 当前是否白天模式（页面里想做差异化处理时用） */
  static isLight(): boolean {
    return AppTheme.themeMode === ThemeMode.Light;
  }

  /**
   * 切换主题。会自增版本号并写进 AppStorage，
   * 订阅了 `@StorageProp('themeVersion')` 的页面会因此重渲染。
   */
  static setMode(mode: number): void {
    AppTheme.themeMode = mode === ThemeMode.Light ? ThemeMode.Light : ThemeMode.Dark;
    // key 首次不存在时 get 返回 undefined，直接 +1 会得到 NaN —— 那样订阅方永远收不到变化
    const prev: number | undefined = AppStorage.get<number>('themeVersion');
    AppStorage.setOrCreate('themeVersion', (prev === undefined ? 0 : prev) + 1);
  }

  /**
   * 强制让所有订阅方重渲染一次（不改变当前模式）。
   *
   * ⚠️ 为什么要单独提供这个方法：getter 不是响应式的，一旦某个页面漏加
   *    `@StorageProp('themeVersion')`，它就不会跟着主题变 —— 而这种「漏加」
   *    在新增页面时很容易发生，且症状是「切了主题要大半个界面不刷新」。
   *    `Index.onPageShow()`（从任何页面返回首页都会触发）会调它兜底一次，
   *    把三个页签页连同根节点整体拉齐。
   */
  static refresh(): void {
    const prev: number | undefined = AppStorage.get<number>('themeVersion');
    AppStorage.setOrCreate('themeVersion', (prev === undefined ? 0 : prev) + 1);
  }

  /* ==================== 颜色（按当前色板取值） ==================== */

  /** 页面底色（渐变不可用时的兜底纯色） */
  static get BG(): string {
    return AppTheme.cur().BG;
  }

  /** 背景渐变三段色 */
  static get BG_GRAD_TOP(): string {
    return AppTheme.cur().BG_GRAD_TOP;
  }

  static get BG_GRAD_MID(): string {
    return AppTheme.cur().BG_GRAD_MID;
  }

  static get BG_GRAD_BOTTOM(): string {
    return AppTheme.cur().BG_GRAD_BOTTOM;
  }

  /** 局部面板（弹窗、输入区）用的浅一档渐变 */
  static get PANEL_GRAD_TOP(): string {
    return AppTheme.cur().PANEL_GRAD_TOP;
  }

  static get PANEL_GRAD_BOTTOM(): string {
    return AppTheme.cur().PANEL_GRAD_BOTTOM;
  }

  /** 卡片 / 面板底色 */
  static get CARD(): string {
    return AppTheme.cur().CARD;
  }

  /** 卡片按下态 */
  static get CARD_PRESSED(): string {
    return AppTheme.cur().CARD_PRESSED;
  }

  /** 更亮一档的表面（弹窗、输入框） */
  static get SURFACE(): string {
    return AppTheme.cur().SURFACE;
  }

  /** 分割线 */
  static get LINE(): string {
    return AppTheme.cur().LINE;
  }

  static get TEXT_PRIMARY(): string {
    return AppTheme.cur().TEXT_PRIMARY;
  }

  static get TEXT_SECONDARY(): string {
    return AppTheme.cur().TEXT_SECONDARY;
  }

  static get TEXT_TERTIARY(): string {
    return AppTheme.cur().TEXT_TERTIARY;
  }

  /** 主色（选中态、播放按钮） */
  static get ACCENT(): string {
    return AppTheme.cur().ACCENT;
  }

  static get ACCENT_SOFT(): string {
    return AppTheme.cur().ACCENT_SOFT;
  }

  /** 评分金色 */
  static get GOLD(): string {
    return AppTheme.cur().GOLD;
  }

  /** 图片占位底 */
  static get PLACEHOLDER(): string {
    return AppTheme.cur().PLACEHOLDER;
  }

  /** 已看完的选集按钮 */
  static get EP_DONE_BG(): string {
    return AppTheme.cur().EP_DONE_BG;
  }

  static get EP_DONE_TEXT(): string {
    return AppTheme.cur().EP_DONE_TEXT;
  }

  /** 评分标签底色 */
  static get BADGE_BG(): string {
    return AppTheme.cur().BADGE_BG;
  }

  /** 视频页 / 沉浸式页面底色（两个主题都保持纯黑） */
  static get VIDEO_BG(): string {
    return AppTheme.cur().VIDEO_BG;
  }

  /** 底部页签栏背景 */
  static get TAB_BAR_BG(): string {
    return AppTheme.cur().TAB_BAR_BG;
  }

  /* ==================== 与颜色无关的尺寸常量（两个主题共用） ==================== */

  static readonly RADIUS_CARD: number = 10;
  static readonly RADIUS_PILL: number = 16;
  static readonly PAGE_PADDING: number = 12;
}
