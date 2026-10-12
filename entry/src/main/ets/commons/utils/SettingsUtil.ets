import { HttpUtil } from './HttpUtil';
import { Store } from './StoreUtil';
import { Log } from './LogUtil';

const TAG = 'AppSettings';
const KEY_SETTINGS = 'app_settings';

/** 可选值 */
export const HISTORY_OPTIONS: number[] = [50, 100, 200, 500];
export const PAGE_SIZE_OPTIONS: number[] = [20, 30, 40, 60];
export const SPEED_OPTIONS: number[] = [0.75, 1.0, 1.25, 1.5, 2.0];
/** 0 表示「不限制」 */
export const RECONNECT_OPTIONS: number[] = [0, 1, 3, 5];

/**
 * 设置项的原始形态（preferences 里反序列化出来的是裸对象）。
 */
export interface RawSettings {
  maxHistory?: number;
  pageSize?: number;
  defaultSpeed?: number;
  autoNext?: boolean;
  /** 播放失败最多自动重连几次，0 = 不重连 */
  reconnectTimes?: number;
  /** 竖屏时默认是否全屏播放 */
  autoFullscreen?: boolean;
  /** 主题模式：0 黑夜 / 1 白天，见 ThemeMode */
  themeMode?: number;
}

/** 全局设置。字段少，整体存一段 JSON 比拆多个 key 好维护。 */
export class AppSettingsData {
  /** 播放历史最多保留条数 */
  maxHistory: number = 100;
  /** 分类列表每页条数 */
  pageSize: number = 20;
  /** 播放页默认倍速 */
  defaultSpeed: number = 1.0;
  /** 播完自动下一集 */
  autoNext: boolean = true;
  /** 播放失败自动重连次数，0 = 关闭 */
  reconnectTimes: number = 1;
  /** 进入播放页默认全屏 */
  autoFullscreen: boolean = true;
  /** 主题模式：ThemeMode.Dark(0) / ThemeMode.Light(1) */
  themeMode: number = 0;
}

/**
 * 设置读写（单例）。
 * 用 ensure() 在首个页面初始化时加载一次，之后各处直接 current() 同步读取。
 */
export class AppSettings {
  private static inst: AppSettingsData = new AppSettingsData();
  private static ready: boolean = false;
  private static initPromise: Promise<AppSettingsData> | undefined = undefined;

  static async ensure(): Promise<AppSettingsData> {
    if (AppSettings.ready) {
      return AppSettings.inst;
    }
    if (AppSettings.initPromise === undefined) {
      AppSettings.initPromise = AppSettings.doLoad();
    }
    return await AppSettings.initPromise;
  }

  private static async doLoad(): Promise<AppSettingsData> {
    try {
      const raw: string = await Store.getString(KEY_SETTINGS, '');
      if (raw.length > 0) {
        const parsed = HttpUtil.parseJson<RawSettings>(raw, 'settings');
        if (parsed !== undefined) {
          AppSettings.inst = AppSettings.normalize(parsed);
        }
      }
    } catch (e) {
      Log.w(TAG, `load failed: ${e}`);
    }
    AppSettings.ready = true;
    return AppSettings.inst;
  }

  /** 同步读取当前设置（没加载过就是默认值） */
  static current(): AppSettingsData {
    return AppSettings.inst;
  }

  static async save(): Promise<void> {
    await Store.putString(KEY_SETTINGS, JSON.stringify(AppSettings.inst));
    Log.i(TAG, `saved maxHistory=${AppSettings.inst.maxHistory} speed=${AppSettings.inst.defaultSpeed}`);
  }

  /** 直接替换整个设置对象（还原备份用） */
  static async replace(raw: RawSettings | undefined): Promise<void> {
    AppSettings.inst = AppSettings.normalize(raw);
    AppSettings.ready = true;
    await AppSettings.save();
  }

  /** 备份导出用 */
  static toJson(): string {
    return JSON.stringify(AppSettings.inst);
  }

  private static normalize(raw: RawSettings | undefined): AppSettingsData {
    const d: AppSettingsData = new AppSettingsData();
    if (raw === undefined || raw === null) {
      return d;
    }
    d.maxHistory = AppSettings.pick(raw.maxHistory, HISTORY_OPTIONS, d.maxHistory);
    d.pageSize = AppSettings.pick(raw.pageSize, PAGE_SIZE_OPTIONS, d.pageSize);
    d.defaultSpeed = AppSettings.pickFloat(raw.defaultSpeed, d.defaultSpeed);
    d.autoNext = raw.autoNext === undefined ? d.autoNext : raw.autoNext === true;
    d.reconnectTimes = AppSettings.pick(raw.reconnectTimes, RECONNECT_OPTIONS, d.reconnectTimes);
    d.autoFullscreen = raw.autoFullscreen === undefined ? d.autoFullscreen : raw.autoFullscreen === true;
    // 主题只允许 0/1，别的值一律退回黑夜，避免手改备份塞进越界值
    d.themeMode = raw.themeMode === 1 ? 1 : 0;
    return d;
  }

  /** 数值必须是候选之一，否则退回默认（防止手改备份文件塞进离谱的值） */
  private static pick(v: number | undefined, options: number[], def: number): number {
    if (v === undefined || v === null || typeof v !== 'number' || isNaN(v)) {
      return def;
    }
    for (let i = 0; i < options.length; i++) {
      if (options[i] === v) {
        return v;
      }
    }
    return def;
  }

  private static pickFloat(v: number | undefined, def: number): number {
    if (v === undefined || v === null || typeof v !== 'number' || isNaN(v)) {
      return def;
    }
    if (v < 0.25 || v > 4) {
      return def;
    }
    return v;
  }
}
