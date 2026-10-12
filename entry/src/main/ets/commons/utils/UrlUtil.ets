import { MEDIA_EXTENSIONS } from '../constants/Constants';

/**
 * URL / 字符串处理工具。
 * 影视源返回的图片与播放地址五花八门（相对路径、协议相对、带转义），这里统一收敛。
 */
export class UrlUtil {
  /** 是否 http(s) 地址 */
  static isHttp(url: string): boolean {
    if (url === undefined) {
      return false;
    }
    const u: string = url.trim().toLowerCase();
    return u.startsWith('http://') || u.startsWith('https://');
  }

  /** 是否可直接播放的媒体地址 */
  static isMediaUrl(url: string): boolean {
    if (url === undefined || url.length === 0) {
      return false;
    }
    let u: string = url.trim().toLowerCase();
    const q: number = u.indexOf('?');
    if (q > 0) {
      u = u.substring(0, q);
    }
    const h: number = u.indexOf('#');
    if (h > 0) {
      u = u.substring(0, h);
    }
    for (let i = 0; i < MEDIA_EXTENSIONS.length; i++) {
      if (u.endsWith(MEDIA_EXTENSIONS[i])) {
        return true;
      }
    }
    // 没有后缀但明显是流地址的（如 /live/xxx 或 m3u8 在 query 里）
    const lower: string = url.toLowerCase();
    return lower.indexOf('.m3u8') >= 0 || lower.indexOf('mime=m3u8') >= 0;
  }

  /** 把相对地址补成绝对地址 */
  static absolutize(baseUrl: string, url: string): string {
    if (url === undefined || url.length === 0) {
      return '';
    }
    const u: string = url.trim();
    if (UrlUtil.isHttp(u)) {
      return u;
    }
    if (u.startsWith('//')) {
      return 'https:' + u;
    }
    if (!UrlUtil.isHttp(baseUrl)) {
      return u;
    }
    if (u.startsWith('/')) {
      const idx: number = UrlUtil.hostEnd(baseUrl);
      return baseUrl.substring(0, idx) + u;
    }
    const lastSlash: number = baseUrl.lastIndexOf('/');
    if (lastSlash > 8) {
      return baseUrl.substring(0, lastSlash + 1) + u;
    }
    return baseUrl + '/' + u;
  }

  /** 取 base 的协议+host 结束位置 */
  private static hostEnd(baseUrl: string): number {
    const schemeEnd: number = baseUrl.indexOf('://');
    if (schemeEnd < 0) {
      return 0;
    }
    const pathStart: number = baseUrl.indexOf('/', schemeEnd + 3);
    return pathStart < 0 ? baseUrl.length : pathStart;
  }

  /** 取站点根地址，如 https://a.com/api.php/provide/vod/ -> https://a.com */
  static originOf(url: string): string {
    if (!UrlUtil.isHttp(url)) {
      return '';
    }
    const start: number = url.indexOf('://') + 3;
    const idx: number = url.indexOf('/', start);
    return idx < 0 ? url : url.substring(0, idx);
  }

  /** 图片地址修正：补协议、补域名 */
  static fixPic(baseUrl: string, pic: string): string {
    if (pic === undefined || pic === null || pic.length === 0) {
      return '';
    }
    let p: string = pic.trim();
    if (p.startsWith('//')) {
      return 'https:' + p;
    }
    if (UrlUtil.isHttp(p)) {
      return p;
    }
    return UrlUtil.absolutize(baseUrl, p);
  }

  /** api 地址拼接：自动判断用 ? 还是 & */
  static appendQuery(api: string, query: string): string {
    if (api === undefined) {
      return query;
    }
    const sep: string = api.indexOf('?') >= 0 ? '&' : '?';
    return api + sep + query;
  }

  /**
   * 去掉 api 里的 ac 参数。
   *
   * 很多配置把采集站 api 写成 `.../provide/vod?ac=list`（TVBox 站点检测的写法）。
   * 我们请求时会再拼一个 `ac=videolist`，于是变成 `?ac=list&ac=videolist&t=6`。
   * PHP 的 $_GET 取「同名参数的最后一个」才碰巧正常，遇到取第一个的服务端就会
   * 一直返回分类列表而不是影片列表。统一在配置加载时清掉，其余参数原样保留。
   */
  static stripAcParam(api: string): string {
    if (api === undefined || api.length === 0) {
      return api;
    }
    const q: number = api.indexOf('?');
    if (q < 0) {
      return api;
    }
    const base: string = api.substring(0, q);
    const parts: string[] = api.substring(q + 1).split('&');
    const kept: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i];
      if (p.length === 0) {
        continue;
      }
      const eq: number = p.indexOf('=');
      const k: string = eq < 0 ? p : p.substring(0, eq);
      if (k.toLowerCase() === 'ac') {
        continue;
      }
      kept.push(p);
    }
    return kept.length > 0 ? `${base}?${kept.join('&')}` : base;
  }

  /** 关键词编码 */
  static encodeKeyword(wd: string): string {
    return encodeURIComponent(wd.trim());
  }

  /** 去掉 HTML 标签 + 实体，用于简介 */
  static stripHtml(html: string): string {
    if (html === undefined || html.length === 0) {
      return '';
    }
    let s: string = html;
    s = s.replace(/<br\s*\/?>/gi, '\n');
    s = s.replace(/<[^>]+>/g, '');
    s = s.replace(/&nbsp;/g, ' ');
    s = s.replace(/&amp;/g, '&');
    s = s.replace(/&quot;/g, '"');
    s = s.replace(/&#39;/g, '\'');
    s = s.replace(/&lt;/g, '<');
    s = s.replace(/&gt;/g, '>');
    return s.trim();
  }

  /** 解析 SiteModel.ext 里的 {wd} / {pg} 模板 */
  static applyTemplate(tpl: string, wd: string, page: number): string {
    let s: string = tpl;
    s = s.replace(/\{wd\}/g, UrlUtil.encodeKeyword(wd));
    s = s.replace(/\{pg\}/g, String(page));
    s = s.replace(/\{page\}/g, String(page));
    return s;
  }

  /** 秒 -> mm:ss / hh:mm:ss */
  static formatTime(seconds: number): string {
    if (seconds === undefined || seconds < 0 || !isFinite(seconds)) {
      return '00:00';
    }
    const total: number = Math.floor(seconds);
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    if (h > 0) {
      const hh: string = h < 10 ? `0${h}` : `${h}`;
      return `${hh}:${mm}:${ss}`;
    }
    return `${mm}:${ss}`;
  }

  /** 从地址里猜一个文件名，作为剧集名兜底 */
  static fileNameOf(url: string): string {
    try {
      const q: number = url.indexOf('?');
      const clean: string = q > 0 ? url.substring(0, q) : url;
      const idx: number = clean.lastIndexOf('/');
      if (idx >= 0 && idx < clean.length - 1) {
        return clean.substring(idx + 1);
      }
    } catch (e) {
      // ignore
    }
    return '';
  }
}
