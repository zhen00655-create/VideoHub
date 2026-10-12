import { VodItem } from './TvBoxModels';

/** 距片尾多少毫秒算「已看完」——只用于兜底判断，主判据是 AVPlayer 的 completed 状态 */
const END_MARGIN_MS: number = 8000;
/** 已看集位图的最大长度，防止异常数据（episodeIndex 被写成 99999）撑爆 preferences */
const WATCHED_MASK_MAX: number = 2000;

/**
 * preferences 里反序列化出来的原始形态。
 * 全部字段可缺失：JSON.parse 出来的是「裸对象」不是 PlayRecord 实例，
 * 且老版本写入的记录没有 durationMs / sourceName / finished。
 * 直接当 PlayRecord 用会在 `.length` / 数值比较上炸掉，所以必须先过 normalize()。
 */
export interface RawPlayRecord {
  siteKey?: string;
  vodId?: string;
  vodName?: string;
  pic?: string;
  sourceIndex?: number;
  sourceName?: string;
  episodeIndex?: number;
  episodeName?: string;
  positionMs?: number;
  durationMs?: number;
  finished?: boolean;
  /** 已看完集的位图（'1'=已看完，下标=集序号） */
  watchedMask?: string;
  /** 当前线路总集数，0 表示未知 */
  totalEpisodes?: number;
  updatedAt?: number;
}

/**
 * 播放记录。
 * 只存续播必需字段，避免 preferences 体积随着观看量线性膨胀。
 */
export class PlayRecord {
  siteKey: string = '';
  vodId: string = '';
  vodName: string = '';
  pic: string = '';
  /** 当前线路序号（线路会被 sortByPlayability 重排，所以只作兜底，优先用 sourceName 对齐） */
  sourceIndex: number = 0;
  /** 当前线路名——跨会话定位线路的可靠依据 */
  sourceName: string = '';
  /** 当前集序号 */
  episodeIndex: number = 0;
  episodeName: string = '';
  /** 续播位置(毫秒) */
  positionMs: number = 0;
  /** 总时长(毫秒)，0 表示未知 */
  durationMs: number = 0;
  /** 是否已看完（看完再进来应该从头播，而不是跳到片尾） */
  finished: boolean = false;
  /**
   * 已看完集的位图：第 i 个字符为 '1' 表示第 i 集已看完。
   * 用字符串而不是 boolean[] 是为了序列化后体积小、且能直接塞进 preferences。
   */
  watchedMask: string = '';
  /** 该剧总集数（当前线路），0 表示未知 */
  totalEpisodes: number = 0;
  updatedAt: number = 0;

  static fromVod(v: VodItem): PlayRecord {
    const r: PlayRecord = new PlayRecord();
    r.siteKey = v.siteKey;
    r.vodId = v.id;
    r.vodName = v.name;
    r.pic = v.pic;
    r.updatedAt = Date.now();
    return r;
  }

  /** 把裸 JSON 对象补全成合法记录，任何字段缺失/类型不对都退回默认值 */
  static normalize(raw: RawPlayRecord | undefined): PlayRecord {
    const r: PlayRecord = new PlayRecord();
    if (!raw) {
      return r;
    }
    r.siteKey = PlayRecord.asString(raw.siteKey);
    r.vodId = PlayRecord.asString(raw.vodId);
    r.vodName = PlayRecord.asString(raw.vodName);
    r.pic = PlayRecord.asString(raw.pic);
    r.sourceIndex = PlayRecord.asNumber(raw.sourceIndex, 0);
    r.sourceName = PlayRecord.asString(raw.sourceName);
    r.episodeIndex = PlayRecord.asNumber(raw.episodeIndex, 0);
    r.episodeName = PlayRecord.asString(raw.episodeName);
    r.positionMs = PlayRecord.asNumber(raw.positionMs, 0);
    r.durationMs = PlayRecord.asNumber(raw.durationMs, 0);
    r.finished = raw.finished === true;
    r.watchedMask = PlayRecord.asMask(raw.watchedMask);
    r.totalEpisodes = PlayRecord.asNumber(raw.totalEpisodes, 0);
    r.updatedAt = PlayRecord.asNumber(raw.updatedAt, 0);
    return r;
  }

  /**
   * 真正要传给播放器的续播位置。
   * 已看完 / 位置落在片尾 8 秒内 → 返回 0（从头播），否则回上次位置。
   */
  static resumeTargetMs(r: PlayRecord | undefined): number {
    if (!r) {
      return 0;
    }
    const pos: number = r.positionMs > 0 ? r.positionMs : 0;
    if (pos <= 0) {
      return 0;
    }
    if (r.finished) {
      return 0;
    }
    if (r.durationMs > 0 && pos >= r.durationMs - END_MARGIN_MS) {
      return 0;
    }
    return pos;
  }

  /** 进度文案：12:34 / 45:00；时长未知时只回位置 */
  static progressText(r: PlayRecord | undefined): string {
    if (!r) {
      return '';
    }
    const pos: number = r.positionMs > 0 ? r.positionMs : 0;
    if (pos <= 0 && r.durationMs <= 0) {
      return '尚未开始播放';
    }
    const cur: string = PlayRecord.mmss(pos);
    if (r.durationMs > 0) {
      return `${cur} / ${PlayRecord.mmss(r.durationMs)}`;
    }
    return cur;
  }

  /* ==================== 多集连播：进度聚合 ==================== */

  /**
   * 「继续观看」该进哪一集。
   * 本集没看完 → 还是本集；本集已看完 → 进下一集（多集连播的核心），
   * 全部看完 → 留在最后一集（按钮会变成「重新播放」）。
   */
  static nextEpisodeIndex(r: PlayRecord | undefined): number {
    if (r === undefined) {
      return 0;
    }
    const cur: number = r.episodeIndex >= 0 ? r.episodeIndex : 0;
    if (!r.finished) {
      return cur;
    }
    if (PlayRecord.allWatched(r)) {
      return cur;
    }
    return cur + 1;
  }

  /** 是否整部剧都看完了（总集数未知时按位图长度兜底） */
  static allWatched(r: PlayRecord | undefined): boolean {
    if (r === undefined) {
      return false;
    }
    const total: number = PlayRecord.totalOf(r);
    return total > 0 && r.watchedCount() >= total;
  }

  /** 总集数：优先用记录里的 totalEpisodes，缺失时退回位图长度 */
  static totalOf(r: PlayRecord): number {
    if (r.totalEpisodes > 0) {
      return r.totalEpisodes;
    }
    return r.watchedMask.length;
  }

  /** 位图里第 idx 位是否为已看完——集列表打标用（dialog 里拿不到 PlayRecord 实例） */
  static isWatchedAt(mask: string | undefined, idx: number): boolean {
    if (mask === undefined || mask === null || idx < 0 || idx >= mask.length) {
      return false;
    }
    return mask.charAt(idx) === '1';
  }

  /** 把第 idx 集标记为已看完（位图按需增长） */
  markWatched(idx: number): void {
    if (idx < 0 || idx >= WATCHED_MASK_MAX) {
      return;
    }
    let m: string = this.watchedMask;
    while (m.length <= idx) {
      m = `${m}0`;
    }
    if (m.charAt(idx) !== '1') {
      m = `${m.substring(0, idx)}1${m.substring(idx + 1)}`;
    }
    this.watchedMask = m;
  }

  isWatched(idx: number): boolean {
    return PlayRecord.isWatchedAt(this.watchedMask, idx);
  }

  /** 已看完的集数 */
  watchedCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.watchedMask.length; i++) {
      if (this.watchedMask.charAt(i) === '1') {
        n = n + 1;
      }
    }
    return n;
  }

  /** 把另一条记录的位图并进来（同一位为 1 即保留）——避免新记录把旧集的观看痕迹冲掉 */
  mergeWatchedFrom(other: PlayRecord | undefined): void {
    if (other === undefined || other.watchedMask.length === 0) {
      return;
    }
    const om: string = other.watchedMask;
    let m: string = this.watchedMask;
    while (m.length < om.length) {
      m = `${m}0`;
    }
    let out: string = '';
    for (let i = 0; i < m.length; i++) {
      out = `${out}${m.charAt(i) === '1' || om.charAt(i) === '1' ? '1' : '0'}`;
    }
    this.watchedMask = out;
  }

  /**
   * 聚合进度：0~1。
   * 已看完的集数占总数，加上「当前集看到一半」那部分——这样进度条在单集内也会爬。
   */
  watchedRatio(): number {
    const total: number = PlayRecord.totalOf(this);
    if (total <= 0) {
      return 0;
    }
    let n: number = this.watchedCount();
    if (!this.isWatched(this.episodeIndex) && this.positionMs > 0 && this.durationMs > 0
      && this.episodeIndex >= 0 && this.episodeIndex < total) {
      let part: number = this.positionMs / this.durationMs;
      if (part > 1) {
        part = 1;
      }
      if (part > 0) {
        n = n + part;
      }
    }
    let ratio: number = n / total;
    if (ratio > 1) {
      ratio = 1;
    }
    if (ratio < 0) {
      ratio = 0;
    }
    return ratio;
  }

  /** 集数聚合文案：已看 3/24 集；总数未知时只给已看数 */
  episodeProgressText(): string {
    const n: number = this.watchedCount();
    if (this.totalEpisodes > 0) {
      return `已看 ${n}/${this.totalEpisodes} 集`;
    }
    if (n > 0) {
      return `已看 ${n} 集`;
    }
    return '';
  }

  private static mmss(ms: number): string {
    const sec: number = Math.max(0, Math.floor(ms / 1000));
    const totalM: number = Math.floor(sec / 60);
    const s: number = sec % 60;
    const h: number = Math.floor(totalM / 60);
    if (h > 0) {
      return `${h}:${PlayRecord.pad(totalM % 60)}:${PlayRecord.pad(s)}`;
    }
    return `${PlayRecord.pad(totalM)}:${PlayRecord.pad(s)}`;
  }

  private static pad(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  /** 字段可能被写成非字符串（老版本/手改过的 JSON），一律降级为空串 */
  private static asString(v: string | undefined): string {
    if (v === undefined || v === null) {
      return '';
    }
    return typeof v === 'string' ? v : '';
  }

  /** 位图容错：只保留 '1'/'0'，超长截断，末尾无意义的 '0' 去掉 */
  private static asMask(v: string | undefined): string {
    if (v === undefined || v === null || typeof v !== 'string') {
      return '';
    }
    const n: number = v.length > WATCHED_MASK_MAX ? WATCHED_MASK_MAX : v.length;
    let out: string = '';
    for (let i = 0; i < n; i++) {
      out = `${out}${v.charAt(i) === '1' ? '1' : '0'}`;
    }
    let end: number = out.length;
    while (end > 0 && out.charAt(end - 1) === '0') {
      end = end - 1;
    }
    return out.substring(0, end);
  }

  private static asNumber(v: number | undefined, def: number): number {
    if (v === undefined || v === null) {
      return def;
    }
    if (typeof v !== 'number' || isNaN(v)) {
      return def;
    }
    return v;
  }
}
