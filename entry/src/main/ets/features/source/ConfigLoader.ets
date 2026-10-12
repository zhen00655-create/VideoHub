import { common } from '@kit.AbilityKit';
import { ConfigModel, SiteModel, ParseModel, ClassModel, WareItemModel } from '../../commons/models/TvBoxModels';
import { HttpUtil, HttpResult } from '../../commons/utils/HttpUtil';
import { FileUtil } from '../../commons/utils/FileUtil';
import { UrlUtil } from '../../commons/utils/UrlUtil';
import { Store } from '../../commons/utils/StoreUtil';
import { Log } from '../../commons/utils/LogUtil';
import {
  BUILTIN_CONFIG_FILE, KEY_CONFIG_URL, PRESET_CONFIG_URLS, SITE_TYPE_JSON, TIMEOUT_CONFIG
} from '../../commons/constants/Constants';

const TAG = 'ConfigManager';
const CACHE_FILE = 'config_cache.json';

/** 一条线路（多仓里的一个子仓） */
export class WareInfo {
  index: number = 0;
  /** 展示名 */
  name: string = '';
  /** 子仓配置地址 */
  url: string = '';
  /** 该仓可用站点数（加载后填充） */
  siteCount: number = 0;
  /** 是否已成功加载过 */
  loaded: boolean = false;
}

/**
 * 配置管理中心（单例）
 *
 * 职责：
 *   1. 下载 / 解析 TVBox JSON 配置（单仓 & 多仓）
 *   2. 三级兜底：网络 → 本地文件缓存 → 内置 rawfile
 *   3. 相对地址补全（多仓里 api/jar 常写相对路径）
 *   4. 站点可用性判定（ArkTS 无法加载 Java JAR，type 3 归为不可用）
 */
export class ConfigManager {
  private static inst: ConfigManager | undefined = undefined;

  /** 本地导入配置的地址前缀；真实内容放在缓存文件里，避免配置文件过大塞进 preferences */
  static readonly LOCAL_PREFIX: string = 'local://';

  static get(): ConfigManager {
    if (ConfigManager.inst === undefined) {
      ConfigManager.inst = new ConfigManager();
    }
    return ConfigManager.inst;
  }

  /** 用户配置的顶层地址 */
  rootUrl: string = '';
  /** 多仓时展开出来的线路；单仓为空 */
  wares: WareInfo[] = [];
  /** 当前生效配置 */
  current: ConfigModel = {};
  /** 当前线路下标，-1 表示单仓 */
  currentWareIndex: number = -1;

  /** 归一化后的可用站点 */
  sites: SiteModel[] = [];
  /** 全部站点（含不可用的 Spider 站） */
  allSites: SiteModel[] = [];
  parses: ParseModel[] = [];
  classes: ClassModel[] = [];

  ready: boolean = false;
  /** 配置来源描述，用于 UI 提示（网络/缓存/内置） */
  sourceDesc: string = '';
  lastError: string = '';

  /** 内置源（rawfile）的展示名，供源管理页「预置源」分区展示 */
  builtinName: string = '';
  /** 内置源里的站点清单（原样保留，含不可用的 Spider 站，便于如实展示） */
  builtinSites: SiteModel[] = [];
  /** 当前生效的是否为内置源 */
  usingBuiltin: boolean = false;

  private blockedKeys: string[] = [];
  private ctx: common.Context | undefined = undefined;
  private initPromise: Promise<void> | undefined = undefined;

  /* ==================== 初始化 ==================== */

  /**
   * 幂等初始化：多个页面（Index / HomePage）可能同时调用，
   * 用同一个 Promise 保证配置只加载一次，后到者直接等待同一个结果。
   */
  async ensureInit(ctx: common.Context): Promise<void> {
    if (this.initPromise === undefined) {
      this.initPromise = this.doInit(ctx);
    }
    await this.initPromise;
  }

  private async doInit(ctx: common.Context): Promise<void> {
    this.ctx = ctx;
    // 先确保 preferences 就绪，否则读配置地址会拿到默认值
    await Store.init(ctx);
    const saved: string = await Store.getString(KEY_CONFIG_URL, '');
    this.blockedKeys = await Store.getStringArray('site_blacklist', []);
    if (saved.length === 0) {
      // 首次启动优先用内置采集站：不依赖 GitHub/jsDelivr 的连通性，秒开有内容。
      // 想要更多源的用户到「源管理」里点预置地址切换（那里是可持久化的）。
      await this.loadBuiltin(ctx);
      if (this.sites.length === 0) {
        await this.loadRoot(PRESET_CONFIG_URLS[0], ctx, true);
      }
    } else if (saved.startsWith(ConfigManager.LOCAL_PREFIX)) {
      // 上次用的是「本地导入」的配置：内容在缓存文件里，直接读，不再联网
      const cached: string = FileUtil.readText(ctx, CACHE_FILE);
      const cfg = HttpUtil.parseJson<ConfigModel>(cached, 'local-cache');
      if (cfg !== undefined && ConfigLoader.collectWareEntries(cfg).length === 0) {
        await this.applyRoot(cfg, saved, ctx, false, '本地导入');
        return;
      }
      Log.w(TAG, 'local config cache missing, fallback to builtin');
      await this.loadBuiltin(ctx);
    } else {
      await this.loadRoot(saved, ctx, false);
    }
  }

  /** 强制重新拉取当前配置源 */
  async reload(ctx: common.Context): Promise<boolean> {
    const url: string = this.rootUrl.length > 0 ? this.rootUrl : PRESET_CONFIG_URLS[0];
    return await this.loadRoot(url, ctx, this.rootUrl.length > 0);
  }


  /** 读取内置兜底配置（rawfile），保证首次启动无网也有内容 */
  async loadBuiltin(ctx: common.Context): Promise<void> {
    this.ctx = ctx;
    const text: string = FileUtil.readRawFile(ctx, BUILTIN_CONFIG_FILE);
    const cfg = HttpUtil.parseJson<ConfigModel>(text, 'builtin');
    if (cfg === undefined) {
      Log.e(TAG, 'builtin config parse failed');
      return;
    }
    this.rootUrl = '';
    this.wares = [];
    this.currentWareIndex = -1;
    this.current = cfg;
    this.sourceDesc = '内置兜底源';
    this.usingBuiltin = true;
    this.builtinName = (cfg.name === undefined || cfg.name.length === 0) ? '内置采集源' : cfg.name;
    this.builtinSites = cfg.sites === undefined ? [] : cfg.sites;
    this.rebuild(ctx, ctx.filesDir);
  }

  /**
   * 切回内置源。
   * 同时清掉持久化的配置地址，否则下次启动又会去加载那个（可能已经失联的）网络源。
   */
  async useBuiltin(ctx: common.Context): Promise<boolean> {
    await Store.putString(KEY_CONFIG_URL, '');
    await this.loadBuiltin(ctx);
    this.lastError = '';
    Log.i(TAG, `switch to builtin, usable=${this.sites.length}`);
    return this.sites.length > 0;
  }

  /**
   * 从本地文件内容加载配置（设置页「本地导入」）。
   * 只支持单仓：多仓的线路列表需要联网下载子仓，本地导入场景下没有意义。
   */
  async loadFromText(text: string, name: string, ctx: common.Context): Promise<boolean> {
    this.ctx = ctx;
    this.lastError = '';
    const body: string = text.trim();
    if (body.length === 0) {
      this.lastError = '文件内容为空';
      return false;
    }
    const cfg = HttpUtil.parseJson<ConfigModel>(body, 'local');
    if (cfg === undefined) {
      this.lastError = '不是合法的 TVBox JSON 配置';
      return false;
    }
    if (ConfigLoader.collectWareEntries(cfg).length > 0) {
      this.lastError = '本地导入暂不支持多仓配置，请导入单仓 JSON';
      return false;
    }
    const ok: boolean = await this.applyRoot(cfg, `${ConfigManager.LOCAL_PREFIX}${name}`, ctx, false, '本地导入');
    if (!ok) {
      return false;
    }
    // 内容写进缓存文件并记住「本地导入」标记，下次启动无需再选文件
    FileUtil.writeText(ctx, CACHE_FILE, body);
    await Store.putString(KEY_CONFIG_URL, `${ConfigManager.LOCAL_PREFIX}${name}`);
    Log.i(TAG, `local import ${name} sites=${this.sites.length} usable=${this.sites.length}`);
    return this.sites.length > 0;
  }

  /* ==================== 顶层加载 ==================== */

  /**
   * 加载顶层配置地址。
   * @param ctx 上下文
   * @param save true 时把地址写入 preferences
   */
  async loadRoot(url: string, ctx: common.Context, save: boolean): Promise<boolean> {
    this.ctx = ctx;
    this.lastError = '';
    const clean: string = url.trim();
    if (clean.length === 0) {
      this.lastError = '配置地址为空';
      return false;
    }

    let text: string = '';
    let source: string = '';

    const res: HttpResult = await HttpUtil.get(clean, undefined, TIMEOUT_CONFIG);
    if (res.ok && res.body.length > 0) {
      text = res.body;
      source = '网络';
      FileUtil.writeText(ctx, CACHE_FILE, text);
    } else {
      this.lastError = res.error;
      const cached: string = FileUtil.readText(ctx, CACHE_FILE);
      if (cached.length > 0) {
        text = cached;
        source = '本地缓存';
        Log.w(TAG, `network failed(${res.error}), fallback to cache`);
      }
    }

    if (text.length === 0) {
      // 最后一层：内置源
      await this.loadBuiltin(ctx);
      this.lastError = `配置加载失败(${this.lastError})，已回退内置源`;
      return false;
    }

    const cfg = HttpUtil.parseJson<ConfigModel>(text, 'root');
    if (cfg === undefined) {
      this.lastError = '配置不是合法 JSON';
      const cached: string = FileUtil.readText(ctx, CACHE_FILE);
      const c2 = HttpUtil.parseJson<ConfigModel>(cached, 'root-cache');
      if (c2 === undefined) {
        await this.loadBuiltin(ctx);
        return false;
      }
      return this.applyRoot(c2, clean, ctx, save, '本地缓存');
    }

    const ok: boolean = await this.applyRoot(cfg, clean, ctx, save, source);
    return ok;
  }

  private async applyRoot(cfg: ConfigModel, url: string, ctx: common.Context,
    save: boolean, source: string): Promise<boolean> {
    const entries: WareItemModel[] = ConfigLoader.collectWareEntries(cfg);
    this.rootUrl = url;
    this.sourceDesc = source;
    this.usingBuiltin = false;

    if (save) {
      await Store.putString(KEY_CONFIG_URL, url);
    }

    if (entries.length > 0) {
      // 多仓：构建线路列表，默认加载第一条
      this.wares = [];
      for (let i = 0; i < entries.length; i++) {
        const w: WareInfo = new WareInfo();
        w.index = i;
        w.url = UrlUtil.absolutize(url, entries[i].url);
        w.name = entries[i].name !== undefined && entries[i].name !== undefined && (entries[i].name as string).length > 0
          ? (entries[i].name as string)
          : ConfigLoader.guessWareName(w.url, i);
        this.wares.push(w);
      }
      Log.i(TAG, `multi-ware total=${this.wares.length}`);
      return await this.selectWare(0, ctx, false);
    }

    // 单仓
    this.wares = [];
    this.currentWareIndex = -1;
    this.current = ConfigLoader.normalizeConfig(url, cfg);
    this.rebuild(ctx, url);
    await this.mergeNestedWares(ctx, url);
    return true;
  }

  /** 多仓选择线路 */
  async selectWare(index: number, ctx: common.Context, persist: boolean = true): Promise<boolean> {
    if (index < 0 || index >= this.wares.length) {
      return false;
    }
    const ware: WareInfo = this.wares[index];
    const res: HttpResult = await HttpUtil.get(ware.url, undefined, TIMEOUT_CONFIG);
    let text: string = '';
    if (res.ok && res.body.length > 0) {
      text = res.body;
    } else {
      this.lastError = `线路「${ware.name}」加载失败: ${res.error}`;
      return false;
    }
    const cfg = HttpUtil.parseJson<ConfigModel>(text, 'ware');
    if (cfg === undefined) {
      this.lastError = `线路「${ware.name}」配置解析失败`;
      return false;
    }

    this.currentWareIndex = index;
    this.current = ConfigLoader.normalizeConfig(ware.url, cfg);
    this.usingBuiltin = false;
    this.rebuild(ctx, ware.url);
    ware.loaded = true;
    ware.siteCount = this.sites.length;

    // 子仓里若还有 url(s)，说明是嵌套仓库，继续摊平
    await this.mergeNestedWares(ctx, ware.url);

    if (persist) {
      await Store.putString(KEY_CONFIG_URL, this.rootUrl);
    }
    Log.i(TAG, `ware[${index}] ${ware.name} sites=${this.sites.length} usable`);
    return true;
  }

  /** 把子仓内嵌的 urls 追加到线路列表（部分仓库是两层结构） */
  private async mergeNestedWares(ctx: common.Context, baseUrl: string): Promise<void> {
    const entries: WareItemModel[] = ConfigLoader.collectWareEntries(this.current);
    if (entries.length === 0) {
      return;
    }
    const extra: WareInfo[] = [];
    for (let i = 0; i < entries.length; i++) {
      const abs: string = UrlUtil.absolutize(baseUrl, entries[i].url);
      let dup: boolean = false;
      for (let j = 0; j < this.wares.length; j++) {
        if (this.wares[j].url === abs) {
          dup = true;
          break;
        }
      }
      if (dup) {
        continue;
      }
      const w: WareInfo = new WareInfo();
      w.url = abs;
      w.name = entries[i].name !== undefined ? (entries[i].name as string) : ConfigLoader.guessWareName(abs, i);
      extra.push(w);
    }
    for (let i = 0; i < extra.length; i++) {
      extra[i].index = this.wares.length;
      this.wares.push(extra[i]);
    }
  }

  /* ==================== 归一化 & 站点筛选 ==================== */

  private rebuild(ctx: common.Context, baseUrl: string): void {
    const cfg: ConfigModel = this.current;
    const list: SiteModel[] = cfg.sites === undefined ? [] : cfg.sites;
    const all: SiteModel[] = [];
    const usable: SiteModel[] = [];

    for (let i = 0; i < list.length; i++) {
      const s: SiteModel = list[i];
      if (s === undefined || s.key === undefined || s.name === undefined) {
        continue;
      }
      // 相对 api 补全
      if (s.api !== undefined && s.api.length > 0 && !UrlUtil.isHttp(s.api)) {
        s.api = UrlUtil.absolutize(baseUrl, s.api);
      }
      // 清掉 api 里预置的 ac=list，避免与后续拼的 ac=videolist 重复（见 UrlUtil.stripAcParam）
      if (s.api !== undefined && s.api.length > 0) {
        s.api = UrlUtil.stripAcParam(s.api);
      }
      all.push(s);
      if (this.isUsable(s)) {
        usable.push(s);
      }
    }

    this.allSites = all;
    this.sites = usable;

    this.parses = cfg.parses === undefined ? [] : cfg.parses;
    this.classes = cfg.classes === undefined ? [] : cfg.classes;
    this.ready = true;

    this.publishStats();
    Log.i(TAG, `config rebuilt: sites total=${all.length} usable=${usable.length} parses=${this.parses.length} classes=${this.classes.length}`);
  }

  /**
   * 把站点数量发布到 AppStorage，供页面用 `@StorageProp` 订阅。
   *
   * ⚠️ 为什么必须显式发布：首页顶部副标题原来是「build 时现读
   *    `ConfigManager.get().sites.length`」—— 那只在「恰好又发生了一次重渲染」时才正确。
   *    冷启动首帧配置还没 rebuild，读到的是空数组，于是显示「0 个可用源」；
   *    等 sites 真的变成 8 时又没有任何响应式信号把它推回界面，就一直停在 0。
   *    （源管理页看起来正常，只是因为它有 `onPageShow → refreshView()` 主动同步。）
   *    写成 AppStorage 后，无论谁、什么时候改了站点，界面都会自动跟上。
   */
  private publishStats(): void {
    AppStorage.setOrCreate('usableSiteCount', this.sites.length);
    AppStorage.setOrCreate('allSiteCount', this.allSites.length);
  }

  /**
   * 站点是否可用。
   * ArkTS 无法加载 Java JAR，因此 type 3(Spider) 一律不可用；
   * type 0(XML) 需要 XML 解析，v1.0 也不支持。只有 type 1(JSON/MacCMS) 走直连。
   */
  isUsable(s: SiteModel): boolean {
    if (s === undefined) {
      return false;
    }
    if (this.blockedKeys.indexOf(s.key) >= 0) {
      return false;
    }
    if (s.type !== SITE_TYPE_JSON) {
      return false;
    }
    if (s.api === undefined || s.api.length === 0) {
      return false;
    }
    if (!UrlUtil.isHttp(s.api)) {
      return false;
    }
    return true;
  }

  /** 不可用原因，用于 UI 灰色提示 */
  unusableReason(s: SiteModel): string {
    if (s.type === 3 || (!UrlUtil.isHttp(s.api === undefined ? '' : s.api))) {
      return '需 Spider(JAR/JS)，ArkTS 不支持';
    }
    if (s.type === 0) {
      return 'XML 接口，v1.0 暂不支持';
    }
    if (this.blockedKeys.indexOf(s.key) >= 0) {
      return '已被禁用';
    }
    return '未知原因';
  }

  async blockSite(key: string): Promise<void> {
    if (this.blockedKeys.indexOf(key) >= 0) {
      return;
    }
    this.blockedKeys.push(key);
    await Store.putStringArray('site_blacklist', this.blockedKeys);
    if (this.ctx !== undefined) {
      this.sites = this.sites.filter((s: SiteModel) => s.key !== key);
    }
    this.publishStats();
  }

  async unblockAll(): Promise<void> {
    this.blockedKeys = [];
    await Store.putStringArray('site_blacklist', []);
    this.publishStats();
  }

  getBlockedKeys(): string[] {
    return this.blockedKeys;
  }

  /** 配置里声明的全局蜘蛛地址（仅展示，不加载） */
  getSpider(): string {
    return this.current.spider === undefined ? '' : this.current.spider;
  }
}

/** 无状态解析工具 */
export class ConfigLoader {
  /** 收集 urls / repositories 里的线路条目 */
  static collectWareEntries(cfg: ConfigModel): WareItemModel[] {
    const out: WareItemModel[] = [];
    ConfigLoader.pushEntries(out, cfg.urls);
    ConfigLoader.pushEntries(out, cfg.repositories);
    return out;
  }

  private static pushEntries(out: WareItemModel[], list: Object[] | undefined): void {
    if (list === undefined || list === null) {
      return;
    }
    for (let i = 0; i < list.length; i++) {
      const item: Object = list[i];
      const t: string = typeof item;
      if (t === 'string') {
        const s: string = item as string;
        if (s.length > 0) {
          const w: WareItemModel = { url: s };
          out.push(w);
        }
      } else if (t === 'object') {
        const o = item as WareItemModel;
        if (o !== undefined && o !== null && o.url !== undefined && o.url.length > 0) {
          // 有些仓库用 {url, name} 或 {api, name}
          const w: WareItemModel = { url: o.url, name: o.name };
          out.push(w);
        }
      }
    }
  }

  /** 把配置里的相对地址补全成绝对地址 */
  static normalizeConfig(baseUrl: string, cfg: ConfigModel): ConfigModel {
    if (cfg.spider !== undefined && cfg.spider.length > 0 && !UrlUtil.isHttp(cfg.spider)) {
      cfg.spider = UrlUtil.absolutize(baseUrl, cfg.spider);
    }
    if (cfg.parses !== undefined) {
      for (let i = 0; i < cfg.parses.length; i++) {
        const p: ParseModel = cfg.parses[i];
        if (p.url !== undefined && p.url.length > 0 && !UrlUtil.isHttp(p.url)) {
          p.url = UrlUtil.absolutize(baseUrl, p.url);
        }
      }
    }
    return cfg;
  }

  /** 从地址猜线路名 */
  static guessWareName(url: string, index: number): string {
    try {
      const q: number = url.indexOf('?');
      let clean: string = q > 0 ? url.substring(0, q) : url;
      if (clean.endsWith('/')) {
        clean = clean.substring(0, clean.length - 1);
      }
      const slash: number = clean.lastIndexOf('/');
      if (slash >= 0 && slash < clean.length - 1) {
        let name: string = clean.substring(slash + 1);
        const dot: number = name.lastIndexOf('.');
        if (dot > 0) {
          name = name.substring(0, dot);
        }
        name = decodeURIComponent(name);
        if (name.length > 0) {
          return name;
        }
      }
      const host: string = UrlUtil.originOf(url);
      if (host.length > 0) {
        return host;
      }
    } catch (e) {
      // ignore
    }
    return `线路${index + 1}`;
  }
}
