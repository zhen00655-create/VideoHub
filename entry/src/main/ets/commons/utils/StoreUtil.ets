import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { SP_NAME } from '../constants/Constants';
import { Log } from './LogUtil';

const TAG = 'Store';

/**
 * preferences 轻量持久化封装。
 * 必须在 EntryAbility.onCreate 里调用 init(context) 完成初始化，
 * 否则首次 get 会因为 Preferences 未就绪而返回默认值。
 */
export class Store {
  private static store: preferences.Preferences | undefined = undefined;

  static async init(ctx: common.Context): Promise<void> {
    if (Store.store !== undefined) {
      return;
    }
    try {
      Store.store = await preferences.getPreferences(ctx, SP_NAME);
      Log.i(TAG, 'preferences initialized');
    } catch (e) {
      Log.e(TAG, `init failed: ${JSON.stringify(e)}`);
    }
  }

  private static ready(): preferences.Preferences | undefined {
    return Store.store;
  }

  static async getString(key: string, def: string): Promise<string> {
    const s = Store.ready();
    if (s === undefined) {
      return def;
    }
    try {
      const v = await s.get(key, def);
      return v as string;
    } catch (e) {
      return def;
    }
  }

  static async putString(key: string, value: string): Promise<void> {
    const s = Store.ready();
    if (s === undefined) {
      return;
    }
    try {
      await s.put(key, value);
      await s.flush();
    } catch (e) {
      Log.e(TAG, `putString ${key} failed: ${JSON.stringify(e)}`);
    }
  }

  static async getStringArray(key: string, def: string[]): Promise<string[]> {
    const s = Store.ready();
    if (s === undefined) {
      return def;
    }
    try {
      const v = await s.get(key, def);
      const arr = v as string[];
      if (arr === undefined || arr === null) {
        return def;
      }
      return arr;
    } catch (e) {
      return def;
    }
  }

  static async putStringArray(key: string, value: string[]): Promise<void> {
    const s = Store.ready();
    if (s === undefined) {
      return;
    }
    try {
      await s.put(key, value);
      await s.flush();
    } catch (e) {
      Log.e(TAG, `putStringArray ${key} failed: ${JSON.stringify(e)}`);
    }
  }
}
