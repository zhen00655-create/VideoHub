import { Store } from './StoreUtil';
import { Log } from './LogUtil';

const TAG = 'IntroMark';

/** 一部片（按片名）的片头/片尾标记，单位秒；0 表示没标 */
export class IntroMark {
  introEndSec: number = 0;
  outroStartSec: number = 0;
}

/**
 * 片头 / 片尾标记。
 *
 * 采集站的播放数据里**没有**片头片尾时间点，自动识别无从谈起，所以只能手动标记：
 * 看到片头结束就点「标记片头」，看到片尾开始就点「标记片尾」，本地按**片名**记住，
 * 下次播这部片时自动跳过——和各大 App 的「跳过片头/片尾」是一个思路，只是由用户标一次。
 * 按片名（而不是 siteKey+vodId）存：换源后 id 全变，只有片名稳定。
 */
export class IntroMarkStore {
  /** 内存缓存，避免每次播放都读一次 preferences */
  private static cache: Map<string, IntroMark> = new Map<string, IntroMark>();

  static async load(vodName: string): Promise<IntroMark> {
    if (vodName.length === 0) {
      return new IntroMark();
    }
    const cached: IntroMark | undefined = IntroMarkStore.cache.get(vodName);
    if (cached !== undefined) {
      return cached;
    }
    const m: IntroMark = new IntroMark();
    try {
      const raw: string = await Store.getString(IntroMarkStore.key(vodName), '');
      if (raw.length > 0) {
        const parts: string[] = raw.split(',');
        if (parts.length >= 2) {
          const a: number = Number.parseFloat(parts[0]);
          const b: number = Number.parseFloat(parts[1]);
          m.introEndSec = isNaN(a) ? 0 : a;
          m.outroStartSec = isNaN(b) ? 0 : b;
        }
      }
    } catch (e) {
      Log.w(TAG, `load failed: ${e}`);
    }
    IntroMarkStore.cache.set(vodName, m);
    return m;
  }

  static async save(vodName: string, m: IntroMark): Promise<void> {
    if (vodName.length === 0) {
      return;
    }
    IntroMarkStore.cache.set(vodName, m);
    try {
      await Store.putString(IntroMarkStore.key(vodName), `${m.introEndSec},${m.outroStartSec}`);
      Log.i(TAG, `save ${vodName} intro=${m.introEndSec} outro=${m.outroStartSec}`);
    } catch (e) {
      Log.w(TAG, `save failed: ${e}`);
    }
  }

  private static key(vodName: string): string {
    return `im_${vodName}`;
  }
}
