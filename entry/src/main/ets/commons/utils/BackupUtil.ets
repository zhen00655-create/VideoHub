import { common } from '@kit.AbilityKit';
import { HttpUtil } from './HttpUtil';
import { Store } from './StoreUtil';
import { PickerUtil } from './PickerUtil';
import { AppSettings, RawSettings } from './SettingsUtil';
import { Log } from './LogUtil';
import {
  KEY_CONFIG_URL, KEY_FAVORITE, KEY_HISTORY, KEY_SITE_BLACKLIST
} from '../constants/Constants';

const TAG = 'BackupUtil';
const KEY_SEARCH_HISTORY = 'search_history';
const BACKUP_TAG = 'yingshicang-backup';
const BACKUP_VERSION = 1;

/** 备份文件结构。字段全部可选，便于跨版本兼容。 */
interface BackupModel {
  tag?: string;
  version?: number;
  exportedAt?: number;
  configUrl?: string;
  history?: string;
  favorite?: string;
  siteBlacklist?: string[];
  searchHistory?: string[];
  settings?: RawSettings;
}

/** 还原结果，用于 toast 文案 */
export class RestoreResult {
  ok: boolean = false;
  message: string = '';
}

/**
 * 数据备份 / 还原。
 *
 * 换设备时把「配置地址 + 播放历史 + 收藏 + 站点禁用 + 设置」打成一个 JSON，
 * 通过系统文件选择器存到用户指定位置；新设备上选这个文件就能整体恢复。
 */
export class BackupUtil {

  /** 导出备份，返回保存后的文件名；'' 表示取消 */
  static async exportTo(ctx: common.UIAbilityContext): Promise<string> {
    try {
      const payload: BackupModel = {
        tag: BACKUP_TAG,
        version: BACKUP_VERSION,
        exportedAt: Date.now(),
        configUrl: await Store.getString(KEY_CONFIG_URL, ''),
        history: await Store.getString(KEY_HISTORY, ''),
        favorite: await Store.getString(KEY_FAVORITE, ''),
        siteBlacklist: await Store.getStringArray(KEY_SITE_BLACKLIST, []),
        searchHistory: await Store.getStringArray(KEY_SEARCH_HISTORY, []),
        settings: BackupUtil.snapshot()
      };
      const name: string = BackupUtil.fileName();
      const uri: string = await PickerUtil.saveText(ctx, name, JSON.stringify(payload));
      if (uri.length === 0) {
        return '';
      }
      Log.i(TAG, `export ok -> ${uri}`);
      return name;
    } catch (e) {
      Log.e(TAG, `export failed: ${e}`);
      return '';
    }
  }

  /** 从用户选择的备份文件还原 */
  static async restoreFrom(ctx: common.UIAbilityContext): Promise<RestoreResult> {
    const out: RestoreResult = new RestoreResult();
    const text: string = await PickerUtil.pickText(ctx, ['.json']);
    if (text.length === 0) {
      out.message = '未选择备份文件';
      return out;
    }
    const data = HttpUtil.parseJson<BackupModel>(text, 'backup');
    if (data === undefined) {
      out.message = '文件不是合法的备份（JSON 解析失败）';
      return out;
    }
    if (data.tag !== undefined && data.tag !== BACKUP_TAG) {
      out.message = '这个文件不是本 App 导出的备份';
      return out;
    }

    let restored: number = 0;
    if (data.configUrl !== undefined) {
      await Store.putString(KEY_CONFIG_URL, data.configUrl);
      restored = restored + 1;
    }
    if (data.history !== undefined && data.history.length > 0) {
      await Store.putString(KEY_HISTORY, data.history);
      restored = restored + 1;
    }
    if (data.favorite !== undefined && data.favorite.length > 0) {
      await Store.putString(KEY_FAVORITE, data.favorite);
      restored = restored + 1;
    }
    if (data.siteBlacklist !== undefined) {
      await Store.putStringArray(KEY_SITE_BLACKLIST, data.siteBlacklist);
      restored = restored + 1;
    }
    if (data.searchHistory !== undefined) {
      await Store.putStringArray(KEY_SEARCH_HISTORY, data.searchHistory);
      restored = restored + 1;
    }
    if (data.settings !== undefined) {
      await AppSettings.replace(data.settings);
      restored = restored + 1;
    }

    if (restored === 0) {
      out.message = '备份里没有任何可还原的数据';
      return out;
    }
    out.ok = true;
    out.message = `已还原 ${restored} 项，配置将在返回首页后重新加载`;
    Log.i(TAG, `restore ok, ${restored} sections`);
    return out;
  }

  private static fileName(): string {
    const d: Date = new Date();
    const y: number = d.getFullYear();
    const m: string = BackupUtil.pad(d.getMonth() + 1);
    const day: string = BackupUtil.pad(d.getDate());
    const hh: string = BackupUtil.pad(d.getHours());
    const mm: string = BackupUtil.pad(d.getMinutes());
    return `yingshicang_backup_${y}${m}${day}_${hh}${mm}.json`;
  }

  private static pad(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  /** 把当前设置拍平成可序列化的裸对象（AppSettingsData 是 class，直接 stringify 会带上不可见字段） */
  private static snapshot(): RawSettings {
    const s = AppSettings.current();
    const raw: RawSettings = {
      maxHistory: s.maxHistory,
      pageSize: s.pageSize,
      defaultSpeed: s.defaultSpeed,
      autoNext: s.autoNext,
      reconnectTimes: s.reconnectTimes,
      autoFullscreen: s.autoFullscreen
    };
    return raw;
  }
}
