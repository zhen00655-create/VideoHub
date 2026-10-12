import { ParseExtModel, ParseModel, SiteModel } from '../../commons/models/TvBoxModels';
import { HttpUtil, HttpResult } from '../../commons/utils/HttpUtil';
import { UrlUtil } from '../../commons/utils/UrlUtil';
import { Log } from '../../commons/utils/LogUtil';
import { PARSE_TYPE_DIRECT, TIMEOUT_PARSE } from '../../commons/constants/Constants';

const TAG = 'ParseResolver';

/** 解析接口可能返回的多种结构 */
export interface ParseDataModel {
  url?: string;
  header?: Record<string, string>;
}

export interface ParseRespModel {
  code?: number;
  msg?: string;
  url?: string;
  videoUrl?: string;
  playurl?: string;
  data?: string | ParseDataModel;
}

export class ParseResult {
  ok: boolean = false;
  /** 可交给 AVPlayer 的最终地址 */
  url: string = '';
  /** 使用的解析器名（直连时为「直连」） */
  parseName: string = '';
  error: string = '';
  /** 需要携带的请求头（防盗链） */
  headers: Record<string, string> | undefined = undefined;
  /** HTTP 解析全部失败，需要走内置网页嗅探 */
  needSniff: boolean = false;
}

/**
 * 解析器调度
 *
 * 处理「网页地址 → 可播放直链」的转换：
 *   type 0  普通嗅探/跳转：直接返回 parse.url + playUrl，由播放器跟随 302
 *   type 1  Json 解析：POST url=<目标地址>，响应取 url 字段
 *   type 2  Json 扩展：同 1，附带 ext 里的额外参数与 header
 *   type 3  聚合：同 1，逐个尝试
 *
 * 全部失败时置 needSniff=true，由播放页启动 WebView 嗅探兜底。
 */
export class ParseResolver {

  /** 判断是否本来就能直接播 */
  static canPlayDirectly(playUrl: string): boolean {
    if (playUrl === undefined || playUrl.length === 0) {
      return false;
    }
    if (!UrlUtil.isHttp(playUrl) && !playUrl.startsWith('rtmp')) {
      return false;
    }
    return UrlUtil.isMediaUrl(playUrl);
  }

  /**
   * 解析播放地址。
   * @param preferredIndex 用户指定的解析器下标；-1 表示自动
   */
  static async resolve(playUrl: string, site: SiteModel, parses: ParseModel[],
    preferredIndex: number): Promise<ParseResult> {
    const out: ParseResult = new ParseResult();
    const target: string = (playUrl === undefined ? '' : playUrl).trim();
    if (target.length === 0) {
      out.error = '播放地址为空';
      return out;
    }

    // 1) 直连
    if (ParseResolver.canPlayDirectly(target)) {
      out.ok = true;
      out.url = target;
      out.parseName = '直连';
      out.headers = site.header;
      return out;
    }

    // 2) 组装候选解析器
    const candidates: ParseModel[] = ParseResolver.buildCandidates(parses, preferredIndex);
    if (candidates.length === 0) {
      out.error = '配置里没有可用的解析器';
      out.needSniff = true;
      return out;
    }

    const errors: string[] = [];
    for (let i = 0; i < candidates.length; i++) {
      const p: ParseModel = candidates[i];
      const r: ParseResult = await ParseResolver.tryOne(target, p, site);
      if (r.ok && r.url.length > 0) {
        return r;
      }
      errors.push(`${p.name}:${r.error}`);
    }

    out.error = errors.join(' | ');
    out.needSniff = true;
    Log.w(TAG, `all parses failed -> ${out.error}`);
    return out;
  }

  /** 按优先级排列解析器：用户指定 > 与站点 flag 匹配 > 其余 */
  static buildCandidates(parses: ParseModel[], preferredIndex: number): ParseModel[] {
    const out: ParseModel[] = [];
    if (parses === undefined || parses.length === 0) {
      return out;
    }
    if (preferredIndex >= 0 && preferredIndex < parses.length) {
      out.push(parses[preferredIndex]);
    }
    for (let i = 0; i < parses.length; i++) {
      if (i === preferredIndex) {
        continue;
      }
      const p: ParseModel = parses[i];
      if (p === undefined || p.url === undefined || p.url.length === 0) {
        continue;
      }
      out.push(p);
    }
    return out;
  }

  private static async tryOne(target: string, p: ParseModel, site: SiteModel): Promise<ParseResult> {
    const out: ParseResult = new ParseResult();
    out.parseName = p.name;

    if (p.url === undefined || p.url.length === 0) {
      out.error = '解析地址为空';
      return out;
    }

    // type 0 —— 前缀拼接，交给播放器跟随重定向
    if (p.type === PARSE_TYPE_DIRECT) {
      out.ok = true;
      out.url = p.url + target;
      out.headers = ParseResolver.mergeHeaders(site, p.ext);
      return out;
    }

    const headers: Record<string, string> = ParseResolver.extHeaders(p.ext);
    const extra: Record<string, string> = ParseResolver.extParams(p.ext);

    // type 1/2/3 —— POST form（key 必须带引号，否则 ArkTS 会按「结构化对象」校验而报 untyped-obj-literals）
    const form: Record<string, string> = { 'url': target };
    const extraKeys: string[] = Object.keys(extra);
    for (let i = 0; i < extraKeys.length; i++) {
      form[extraKeys[i]] = extra[extraKeys[i]];
    }

    let res: HttpResult = await HttpUtil.postForm(p.url, form, headers, TIMEOUT_PARSE);
    let found: string = '';
    if (res.ok && res.body.length > 0) {
      found = ParseResolver.extractUrl(res.body);
    }

    // POST 无果时尝试 GET 拼接（部分解析服务只认 GET）
    if (found.length === 0) {
      const getUrl: string = UrlUtil.appendQuery(p.url, `url=${encodeURIComponent(target)}`);
      res = await HttpUtil.get(getUrl, headers, TIMEOUT_PARSE);
      if (res.ok && res.body.length > 0) {
        found = ParseResolver.extractUrl(res.body);
      }
    }

    if (found.length === 0) {
      out.error = res.error.length > 0 ? res.error : '解析结果为空';
      return out;
    }

    out.ok = true;
    out.url = found;
    out.headers = ParseResolver.mergeHeaders(site, p.ext);
    Log.i(TAG, `parse ok via ${p.name}: ${UrlUtil.isMediaUrl(found) ? 'direct-media' : 'maybe-web'}`);
    return out;
  }

  /* ==================== 响应提取 ==================== */

  /** 从解析响应里挖出播放地址，兼容 5 种常见结构 */
  static extractUrl(body: string): string {
    const text: string = body.trim();
    if (text.length === 0) {
      return '';
    }

    // 纯地址
    if (UrlUtil.isMediaUrl(text)) {
      return text;
    }

    const brace: number = text.indexOf('{');
    if (brace < 0) {
      // 可能是 http://... 的裸地址（无 JSON）
      if (UrlUtil.isHttp(text) && text.indexOf('\n') < 0 && text.length < 2048) {
        return ParseResolver.decodeIfNeeded(text);
      }
      return '';
    }

    const json: string = text.substring(brace);
    const resp = HttpUtil.parseJson<ParseRespModel>(json, 'parse-resp');
    if (resp === undefined) {
      return '';
    }

    let candidate: string = '';
    if (resp.url !== undefined && resp.url.length > 0) {
      candidate = resp.url;
    } else if (resp.videoUrl !== undefined && resp.videoUrl.length > 0) {
      candidate = resp.videoUrl;
    } else if (resp.playurl !== undefined && resp.playurl.length > 0) {
      candidate = resp.playurl;
    } else if (resp.data !== undefined) {
      const d = resp.data;
      if (typeof d === 'string') {
        candidate = d;
      } else {
        const dm = d as ParseDataModel;
        if (dm !== undefined && dm.url !== undefined && dm.url.length > 0) {
          candidate = dm.url;
        }
      }
    }

    if (candidate.length === 0) {
      return '';
    }
    return ParseResolver.decodeIfNeeded(candidate.trim());
  }

  /** 有些解析服务把地址做了 URL 编码 */
  private static decodeIfNeeded(url: string): string {
    if (url.indexOf('%3A') >= 0 || url.indexOf('%2F') >= 0 || url.indexOf('%3a') >= 0) {
      try {
        return decodeURIComponent(url);
      } catch (e) {
        return url;
      }
    }
    return url;
  }

  /* ==================== ext 处理 ==================== */

  static extHeaders(ext: ParseExtModel | undefined): Record<string, string> {
    const out: Record<string, string> = {};
    if (ext === undefined) {
      return out;
    }
    if (ext.ua !== undefined && ext.ua.length > 0) {
      out['User-Agent'] = ext.ua;
    }
    if (ext.referer !== undefined && ext.referer.length > 0) {
      out['Referer'] = ext.referer;
    }
    if (ext.header !== undefined && ext.header !== null) {
      const keys: string[] = Object.keys(ext.header);
      for (let i = 0; i < keys.length; i++) {
        out[keys[i]] = ext.header[keys[i]];
      }
    }
    return out;
  }

  /** ext 里除 flag/header/ua/referer 之外的键都作为附加 POST 参数 */
  private static extParams(ext: ParseExtModel | undefined): Record<string, string> {
    const out: Record<string, string> = {};
    if (ext === undefined) {
      return out;
    }
    if (ext.format !== undefined && ext.format.length > 0) {
      out['format'] = ext.format;
    }
    return out;
  }

  private static mergeHeaders(site: SiteModel, ext: ParseExtModel | undefined): Record<string, string> | undefined {
    const merged: Record<string, string> = {};
    let has: boolean = false;
    if (site.header !== undefined && site.header !== null) {
      const k1: string[] = Object.keys(site.header);
      for (let i = 0; i < k1.length; i++) {
        merged[k1[i]] = site.header[k1[i]];
        has = true;
      }
    }
    const eh: Record<string, string> = ParseResolver.extHeaders(ext);
    const k2: string[] = Object.keys(eh);
    for (let i = 0; i < k2.length; i++) {
      merged[k2[i]] = eh[k2[i]];
      has = true;
    }
    return has ? merged : undefined;
  }
}
