import {
  ClassListResp, ClassModel, SiteModel, VodItem, VodListResp, VodRawModel
} from '../../commons/models/TvBoxModels';
import { HttpUtil, HttpResult } from '../../commons/utils/HttpUtil';
import { UrlUtil } from '../../commons/utils/UrlUtil';
import { Log } from '../../commons/utils/LogUtil';
import { TIMEOUT_API } from '../../commons/constants/Constants';

const TAG = 'SiteRouter';

/** 一个已选中的筛选条件 */
export class FilterSel {
  key: string = '';
  value: string = '';
}

/** 一次列表请求的结果 */
export class VodPage {
  ok: boolean = false;
  error: string = '';
  page: number = 1;
  pageCount: number = 1;
  total: number = 0;
  items: VodItem[] = [];
}

/**
 * 站点请求路由
 *
 * 负责把「站点 + 动作」翻译成 MacCMS(苹果CMS v10 provide/vod) 的 HTTP 请求，
 * 并把响应归一化成 VodItem。
 *
 * 请求约定（与 TVBox ApiConfig 对齐）：
 *   搜索   api + ext(替换 {wd}/{pg})      缺省: ?ac=videolist&wd={wd}&pg={pg}
 *   分类   ext 含 {cateId} 时用 ext，     缺省: ?ac=videolist&t={typeId}&pg={page}
 *         再追加筛选条件 &key=value
 *   详情   ?ac=detail&ids={id} 优先，失败回退 ?ac=videolist&ids={id}
 *   分类   ?ac=list 的 class 字段
 */
export class SiteRouter {

  /* ==================== 搜索 ==================== */

  static async search(site: SiteModel, wd: string, page: number): Promise<VodPage> {
    const urlVideolist: string = SiteRouter.buildSearchUrl(site, wd, page);
    let r: VodPage = await SiteRouter.fetchList(site, urlVideolist);
    if (r.ok && r.items.length === 0) {
      // 少数源只实现了 ac=detail
      const urlDetail: string = UrlUtil.appendQuery(site.api,
        `ac=detail&wd=${UrlUtil.encodeKeyword(wd)}&pg=${page}`);
      const r2: VodPage = await SiteRouter.fetchList(site, urlDetail);
      if (r2.ok && r2.items.length > 0) {
        return r2;
      }
    }
    return r;
  }

  /* ==================== 分类 ==================== */

  /**
   * 最近更新。
   *
   * 这是唯一在所有采集站上都能拿到数据的请求：
   *   `?ac=videolist&h=24` 取 24 小时内更新，站点不支持 h 时退回 `?ac=videolist`（全量最新）。
   * 首页第一个页签走这里，避免首屏出现空列表（MacCMS 的父分类 t=1 在多数站点返回 0 条）。
   */
  static async latest(site: SiteModel, page: number): Promise<VodPage> {
    const urlHours: string = UrlUtil.appendQuery(site.api, `ac=videolist&h=24&pg=${page}`);
    const r1: VodPage = await SiteRouter.fetchList(site, urlHours);
    if (r1.ok && r1.items.length > 0) {
      return r1;
    }
    const urlAll: string = UrlUtil.appendQuery(site.api, `ac=videolist&pg=${page}`);
    const r2: VodPage = await SiteRouter.fetchList(site, urlAll);
    if (r2.ok && r2.items.length > 0) {
      return r2;
    }
    return r1.ok ? r1 : r2;
  }

  static async category(site: SiteModel, typeId: string, page: number, filters: FilterSel[]): Promise<VodPage> {
    const url: string = SiteRouter.buildCategoryUrl(site, typeId, page, filters);
    const r: VodPage = await SiteRouter.fetchList(site, url);
    if (r.ok && r.items.length === 0) {
      const fallback: string = SiteRouter.buildCategoryUrlDefault(site, typeId, page, filters, 'detail');
      if (fallback !== url) {
        const r2: VodPage = await SiteRouter.fetchList(site, fallback);
        if (r2.ok && r2.items.length > 0) {
          return r2;
        }
      }
    }
    return r;
  }

  /* ==================== 详情 ==================== */

  static async detail(site: SiteModel, vodId: string): Promise<VodItem | undefined> {
    const id: string = encodeURIComponent(vodId);
    const url1: string = UrlUtil.appendQuery(site.api, `ac=detail&ids=${id}`);
    const v1: VodItem | undefined = await SiteRouter.fetchOne(site, url1);
    if (v1 !== undefined && v1.playUrl !== undefined && v1.playUrl.length > 0) {
      return v1;
    }
    const url2: string = UrlUtil.appendQuery(site.api, `ac=videolist&ids=${id}`);
    const v2: VodItem | undefined = await SiteRouter.fetchOne(site, url2);
    if (v2 !== undefined && (v2.playUrl === undefined || v2.playUrl.length === 0)) {
      // 两次都没有播放地址，优先返回信息更全的那个
      if (v1 !== undefined) {
        return v1;
      }
    }
    if (v2 !== undefined) {
      return v2;
    }
    return v1;
  }

  /** 同时按多个站点并发搜索，按站点顺序合并 */
  static async searchAll(sites: SiteModel[], wd: string, page: number): Promise<VodItem[]> {
    if (sites.length === 0) {
      return [];
    }
    const tasks: Promise<VodPage>[] = [];
    const use: SiteModel[] = sites.slice(0, 20);
    for (let i = 0; i < use.length; i++) {
      tasks.push(SiteRouter.search(use[i], wd, page));
    }
    const pages: VodPage[] = await Promise.all(tasks);
    const out: VodItem[] = [];
    for (let i = 0; i < pages.length; i++) {
      const p: VodPage = pages[i];
      if (p.ok) {
        for (let j = 0; j < p.items.length; j++) {
          out.push(p.items[j]);
        }
      }
    }
    return out;
  }

  /* ==================== 分类列表 ==================== */

  static async classes(site: SiteModel): Promise<ClassModel[]> {
    const url: string = UrlUtil.appendQuery(site.api, 'ac=list');
    const res: HttpResult = await HttpUtil.get(url, undefined, TIMEOUT_API);
    if (!res.ok || res.body.length === 0) {
      return [];
    }
    const body: string = HttpUtil.stripJsonp(res.body);
    const resp = HttpUtil.parseJson<ClassListResp>(body, `classes:${site.key}`);
    if (resp === undefined || resp.class === undefined) {
      return [];
    }
    return resp.class;
  }

  /* ==================== 内部实现 ==================== */

  private static async fetchOne(site: SiteModel, url: string): Promise<VodItem | undefined> {
    const page: VodPage = await SiteRouter.fetchList(site, url);
    if (!page.ok || page.items.length === 0) {
      return undefined;
    }
    return page.items[0];
  }

  private static async fetchList(site: SiteModel, url: string): Promise<VodPage> {
    const out: VodPage = new VodPage();
    out.page = 1;

    const res: HttpResult = await HttpUtil.get(url, SiteRouter.siteHeaders(site), TIMEOUT_API);
    if (!res.ok || res.body.length === 0) {
      out.error = res.error.length > 0 ? res.error : '响应为空';
      Log.w(TAG, `[${site.name}] list failed: ${out.error} url=${url}`);
      return out;
    }

    const body: string = HttpUtil.stripJsonp(res.body);
    const resp = HttpUtil.parseJson<VodListResp>(body, `list:${site.key}`);
    if (resp === undefined) {
      out.error = '数据格式不是 JSON(MacCMS)';
      Log.w(TAG, `[${site.name}] not json, body=${HttpUtil.head(res.body, 160)}`);
      return out;
    }

    out.items = SiteRouter.mapList(site, resp.list);
    if (out.items.length === 0) {
      // 空列表是影视源最常见的状态（分类不存在 / type_id 是父分类），把原始响应打出来便于定位
      Log.w(TAG, `[${site.name}] empty list url=${url} body=${HttpUtil.head(body, 160)}`);
    }
    out.total = SiteRouter.toNum(resp.total);
    out.pageCount = SiteRouter.toNum(resp.pagecount);
    if (out.pageCount <= 0) {
      out.pageCount = 1;
    }
    out.page = SiteRouter.toNum(resp.page);
    if (out.page <= 0) {
      out.page = 1;
    }
    out.ok = (resp.code === undefined || resp.code === 1 || resp.code === 0) || out.items.length > 0;
    if (!out.ok) {
      out.error = resp.msg === undefined ? '接口返回失败' : resp.msg;
    }
    return out;
  }

  private static mapList(site: SiteModel, list: VodRawModel[] | undefined): VodItem[] {
    const out: VodItem[] = [];
    if (list === undefined || list === null) {
      return out;
    }
    for (let i = 0; i < list.length; i++) {
      const raw: VodRawModel = list[i];
      if (raw === undefined || raw === null) {
        continue;
      }
      const v: VodItem = new VodItem();
      v.siteKey = site.key;
      v.siteName = site.name;
      v.id = SiteRouter.toStr(raw.vod_id);
      if (v.id.length === 0) {
        continue;
      }
      v.name = SiteRouter.str(raw.vod_name);
      v.pic = UrlUtil.fixPic(site.api, SiteRouter.str(raw.vod_pic));
      v.remarks = SiteRouter.str(raw.vod_remarks);
      v.year = SiteRouter.str(raw.vod_year);
      v.area = SiteRouter.str(raw.vod_area);
      v.typeName = SiteRouter.str(raw.type_name);
      v.score = SiteRouter.str(raw.vod_score);
      v.actor = SiteRouter.str(raw.vod_actor);
      v.director = SiteRouter.str(raw.vod_director);
      const content: string = SiteRouter.str(raw.vod_content).length > 0
        ? SiteRouter.str(raw.vod_content) : SiteRouter.str(raw.vod_blurb);
      v.content = UrlUtil.stripHtml(content);
      v.playFrom = SiteRouter.str(raw.vod_play_from);
      v.playUrl = SiteRouter.str(raw.vod_play_url);
      out.push(v);
    }
    return out;
  }

  /* ---------- URL 构建 ---------- */

  private static siteHeaders(site: SiteModel): Record<string, string> | undefined {
    return site.header;
  }

  private static buildSearchUrl(site: SiteModel, wd: string, page: number): string {
    const ext: string = site.ext === undefined ? '' : site.ext;
    if (ext.length > 0 && ext.indexOf('{wd}') >= 0) {
      const applied: string = UrlUtil.applyTemplate(ext, wd, page);
      return SiteRouter.composeExt(site.api, applied);
    }
    return UrlUtil.appendQuery(site.api,
      `ac=videolist&wd=${UrlUtil.encodeKeyword(wd)}&pg=${page}`);
  }

  private static buildCategoryUrl(site: SiteModel, typeId: string, page: number, filters: FilterSel[]): string {
    const ext: string = site.ext === undefined ? '' : site.ext;
    if (ext.indexOf('{cateId}') >= 0 || ext.indexOf('{catePg}') >= 0) {
      let applied: string = ext;
      applied = applied.replace(/\{cateId\}/g, encodeURIComponent(typeId));
      applied = applied.replace(/\{catePg\}/g, String(page));
      applied = applied.replace(/\{pg\}/g, String(page));
      applied = applied.replace(/\{page\}/g, String(page));
      return SiteRouter.appendFilters(SiteRouter.composeExt(site.api, applied), filters);
    }
    return SiteRouter.buildCategoryUrlDefault(site, typeId, page, filters, 'videolist');
  }

  private static buildCategoryUrlDefault(site: SiteModel, typeId: string, page: number,
    filters: FilterSel[], ac: string): string {
    const base: string = UrlUtil.appendQuery(site.api,
      `ac=${ac}&t=${encodeURIComponent(typeId)}&pg=${page}`);
    return SiteRouter.appendFilters(base, filters);
  }

  private static appendFilters(url: string, filters: FilterSel[]): string {
    let u: string = url;
    if (filters === undefined) {
      return u;
    }
    for (let i = 0; i < filters.length; i++) {
      const f: FilterSel = filters[i];
      if (f.key.length === 0 || f.value.length === 0) {
        continue;
      }
      u = UrlUtil.appendQuery(u, `${f.key}=${encodeURIComponent(f.value)}`);
    }
    return u;
  }

  /** 把 ext 模板接到 api 上（'?' / '&' / '/' / 裸 query 四种写法都兼容） */
  private static composeExt(api: string, applied: string): string {
    if (applied === undefined || applied.length === 0) {
      return api;
    }
    const a: string = applied.trim();
    if (a.startsWith('?')) {
      const q: number = api.indexOf('?');
      const base: string = q >= 0 ? api.substring(0, q) : api;
      return base + a;
    }
    if (a.startsWith('&')) {
      return UrlUtil.appendQuery(api, a.substring(1));
    }
    if (a.startsWith('/')) {
      return UrlUtil.originOf(api) + a;
    }
    return UrlUtil.appendQuery(api, a);
  }

  /* ---------- 类型转换 ---------- */

  private static str(v: string | undefined): string {
    return v === undefined || v === null ? '' : v;
  }

  private static toStr(v: number | string | undefined): string {
    if (v === undefined || v === null) {
      return '';
    }
    if (typeof v === 'string') {
      return v;
    }
    return `${v as number}`;
  }

  private static toNum(v: number | string | undefined): number {
    if (v === undefined || v === null) {
      return 0;
    }
    if (typeof v === 'number') {
      return v;
    }
    const n: number = parseInt(v as string, 10);
    return isNaN(n) ? 0 : n;
  }
}
