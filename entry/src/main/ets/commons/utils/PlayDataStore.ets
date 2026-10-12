import { PlayRecord, RawPlayRecord } from '../models/PlayRecordModel';
import { VodItem } from '../models/TvBoxModels';
import { Store } from './StoreUtil';
import { HttpUtil } from './HttpUtil';
import { AppSettings } from './SettingsUtil';
import { Log } from './LogUtil';

const TAG = 'PlayDataStore';
const KEY_HISTORY = 'play_history';
const KEY_FAVORITE = 'favorite_list';
/** 设置不可用时的兜底条数 */
const MAX_HISTORY = 100;
const MAX_FAVORITE = 300;

/**
 * 播放历史 / 收藏。
 * 存储形态是 preferences 里的一段 JSON 字符串 —— PlayRecord 字段固定且少，
 * 序列化开销可以忽略，比拆成多条 preferences key 更好维护。
 */
export class PlayDataStore {
  /**
   * 写串行化。
   * 播放页每 10 秒落一次盘，而「读-改-写」是异步的：两次并发写会各自读到同一份旧值，
   * 后者把前者的结果覆盖掉。用一条链把所有写操作排队，保证顺序执行。
   */
  private static writeChain: Promise<void> = Promise.resolve();

  private static enqueue(job: () => Promise<void>): Promise<void> {
    PlayDataStore.writeChain = PlayDataStore.writeChain.then(job).catch((e: Error) => {
      Log.w(TAG, `write job failed: ${e}`);
    });
    return PlayDataStore.writeChain;
  }

  /* ==================== 历史 ==================== */

  static async loadHistory(): Promise<PlayRecord[]> {
    const raw: string = await Store.getString(KEY_HISTORY, '');
    if (raw.length === 0) {
      return [];
    }
    const arr = HttpUtil.parseJson<RawPlayRecord[]>(raw, 'history');
    if (arr === undefined) {
      return [];
    }
    return PlayDataStore.normalizeAll(arr);
  }

  /** JSON.parse 出来的是裸对象，字段可能缺失（老记录没有 durationMs/sourceName），统一补全 */
  private static normalizeAll(arr: RawPlayRecord[]): PlayRecord[] {
    const out: PlayRecord[] = [];
    for (let i = 0; i < arr.length; i++) {
      const r: RawPlayRecord = arr[i];
      if (!r) {
        continue;
      }
      out.push(PlayRecord.normalize(r));
    }
    return out;
  }

  /** 写入/更新一条历史（同一部片子只保留最新一条，会覆盖旧记录的全部字段） */
  static saveHistory(record: PlayRecord): Promise<void> {
    return PlayDataStore.enqueue(() => PlayDataStore.doOverwrite(record));
  }

  private static async doOverwrite(record: PlayRecord): Promise<void> {
    const list: PlayRecord[] = await PlayDataStore.loadHistory();
    const next: PlayRecord[] = [record];
    for (let i = 0; i < list.length; i++) {
      const r: PlayRecord = list[i];
      if (r !== undefined && !(r.siteKey === record.siteKey && r.vodId === record.vodId)) {
        next.push(r);
      }
    }
    const cap: number = PlayDataStore.maxHistory();
    const capped: PlayRecord[] = next.length > cap ? next.slice(0, cap) : next;
    await Store.putString(KEY_HISTORY, JSON.stringify(capped));
  }

  /**
   * 「合并式」写入：保留旧记录里已看完的集，只更新播放位置 / 线路 / 集号。
   *
   * 为什么不能用 saveHistory 覆盖：播放页每 10 秒落一次盘，而一条记录只带当前集，
   * 直接覆盖会把之前看完的集全部抹掉 ——「已看 X/N 集」永远停在 1。
   */
  static mergeHistory(record: PlayRecord): Promise<void> {
    return PlayDataStore.enqueue(() => PlayDataStore.doMerge(record));
  }

  private static async doMerge(record: PlayRecord): Promise<void> {
    const list: PlayRecord[] = await PlayDataStore.loadHistory();
    let old: PlayRecord | undefined = undefined;
    const next: PlayRecord[] = [];
    for (let i = 0; i < list.length; i++) {
      const r: PlayRecord = list[i];
      if (r === undefined) {
        continue;
      }
      if (r.siteKey === record.siteKey && r.vodId === record.vodId) {
        old = r;
      } else {
        next.push(r);
      }
    }
    if (old !== undefined) {
      record.mergeWatchedFrom(old);
      if (record.totalEpisodes <= 0) {
        record.totalEpisodes = old.totalEpisodes;
      }
    }
    next.unshift(record);
    const cap: number = PlayDataStore.maxHistory();
    const capped: PlayRecord[] = next.length > cap ? next.slice(0, cap) : next;
    await Store.putString(KEY_HISTORY, JSON.stringify(capped));
  }

  static async findHistory(siteKey: string, vodId: string): Promise<PlayRecord | undefined> {
    const list: PlayRecord[] = await PlayDataStore.loadHistory();
    for (let i = 0; i < list.length; i++) {
      const r: PlayRecord = list[i];
      if (r !== undefined && r.siteKey === siteKey && r.vodId === vodId) {
        return r;
      }
    }
    return undefined;
  }

  /**
   * 续播记录查找。
   * 先按 (siteKey, vodId) 精确匹配；找不到再按片名兜底 ——
   * 配置源换站后同一部片的 siteKey/vodId 都会变，只有片名还在。
   * 跨站拿到的记录，集序号要由调用方按「集名」重新对齐（各站集顺序不一致）。
   */
  static async findResume(vodName: string, siteKey: string, vodId: string): Promise<PlayRecord | undefined> {
    const list: PlayRecord[] = await PlayDataStore.loadHistory();
    for (let i = 0; i < list.length; i++) {
      const r: PlayRecord = list[i];
      if (r !== undefined && r.siteKey === siteKey && r.vodId === vodId) {
        return r;
      }
    }
    if (vodName.length === 0) {
      return undefined;
    }
    for (let i = 0; i < list.length; i++) {
      const r: PlayRecord = list[i];
      if (r !== undefined && r.vodName === vodName && r.positionMs > 0) {
        Log.i(TAG, `resume fallback by name: ${vodName} @${r.siteKey}`);
        return r;
      }
    }
    return undefined;
  }

  static async clearHistory(): Promise<void> {
    await Store.putString(KEY_HISTORY, '');
  }

  /** 当前设置里的历史保留条数（设置页可改） */
  private static maxHistory(): number {
    const n: number = AppSettings.current().maxHistory;
    return n > 0 ? n : MAX_HISTORY;
  }

  /* ==================== 收藏 ==================== */

  static async loadFavorites(): Promise<PlayRecord[]> {
    const raw: string = await Store.getString(KEY_FAVORITE, '');
    if (raw.length === 0) {
      return [];
    }
    const arr = HttpUtil.parseJson<RawPlayRecord[]>(raw, 'favorite');
    if (arr === undefined) {
      return [];
    }
    return PlayDataStore.normalizeAll(arr);
  }

  static async isFavorite(siteKey: string, vodId: string): Promise<boolean> {
    const list: PlayRecord[] = await PlayDataStore.loadFavorites();
    for (let i = 0; i < list.length; i++) {
      const r: PlayRecord = list[i];
      if (r !== undefined && r.siteKey === siteKey && r.vodId === vodId) {
        return true;
      }
    }
    return false;
  }

  static async clearFavorites(): Promise<void> {
    await Store.putString(KEY_FAVORITE, '');
  }

  /** 切换收藏，返回切换后的状态 */
  static async toggleFavorite(v: VodItem): Promise<boolean> {
    const list: PlayRecord[] = await PlayDataStore.loadFavorites();
    const next: PlayRecord[] = [];
    let removed: boolean = false;
    for (let i = 0; i < list.length; i++) {
      const r: PlayRecord = list[i];
      if (r !== undefined && r.siteKey === v.siteKey && r.vodId === v.id) {
        removed = true;
      } else {
        next.push(r);
      }
    }
    if (!removed) {
      const r: PlayRecord = PlayRecord.fromVod(v);
      next.unshift(r);
      if (next.length > MAX_FAVORITE) {
        next.splice(MAX_FAVORITE, next.length - MAX_FAVORITE);
      }
    }
    await Store.putString(KEY_FAVORITE, JSON.stringify(next));
    Log.i(TAG, `favorite ${v.name} -> ${!removed}`);
    return !removed;
  }
}
