import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DEFAULT_UA, TIMEOUT_API } from '../constants/Constants';
import { Log } from './LogUtil';

const TAG = 'HttpUtil';

export class HttpResult {
  ok: boolean = false;
  status: number = 0;
  body: string = '';
  error: string = '';
}

/**
 * 统一 HTTP 出口。
 *
 * 设计要点：
 *  1. 每次请求独立创建并 destroy 一个 HttpRequest —— 复用同一个 request 对象在高并发(首页多站点并发)
 *     时会出现结果串号，这也是很多 HarmonyOS 影视 App 首页数据错乱的根因。
 *  2. expectDataType 固定为 STRING，统一由上层 JSON.parse，避免 ArrayBuffer 转换开销。
 *  3. 所有异常都吞掉并转成 HttpResult.error —— 影视聚合场景下单个源挂掉不能影响整体。
 */
export class HttpUtil {
  private static buildHeaders(extra?: Record<string, string>): Record<string, string> {
    const headers: Record<string, string> = {
      'User-Agent': DEFAULT_UA,
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9'
    };
    if (extra !== undefined) {
      const keys: string[] = Object.keys(extra);
      for (let i = 0; i < keys.length; i++) {
        const k: string = keys[i];
        headers[k] = extra[k];
      }
    }
    return headers;
  }

  static async get(url: string, headers?: Record<string, string>, timeoutMs: number = TIMEOUT_API): Promise<HttpResult> {
    const result: HttpResult = new HttpResult();
    if (url === undefined || url.length === 0) {
      result.error = 'empty url';
      return result;
    }
    const req = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: HttpUtil.buildHeaders(headers),
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });
      result.status = resp.responseCode;
      result.ok = resp.responseCode >= 200 && resp.responseCode < 400;
      if (resp.result !== undefined && resp.result !== null) {
        result.body = resp.result as string;
      }
      if (!result.ok) {
        result.error = `HTTP ${resp.responseCode}`;
      }
    } catch (e) {
      const err = e as BusinessError;
      result.error = `${err.code}: ${err.message}`;
      Log.e(TAG, `GET ${url} failed -> ${result.error}`);
    } finally {
      req.destroy();
    }
    return result;
  }

  /** application/x-www-form-urlencoded POST —— 绝大多数解析接口的调用方式 */
  static async postForm(url: string, form: Record<string, string>,
    headers?: Record<string, string>, timeoutMs: number = TIMEOUT_API): Promise<HttpResult> {
    const result: HttpResult = new HttpResult();
    if (url === undefined || url.length === 0) {
      result.error = 'empty url';
      return result;
    }
    const body: string = HttpUtil.encodeForm(form);
    const req = http.createHttp();
    try {
      const hdrs: Record<string, string> = HttpUtil.buildHeaders(headers);
      hdrs['Content-Type'] = 'application/x-www-form-urlencoded';
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.POST,
        header: hdrs,
        extraData: body,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });
      result.status = resp.responseCode;
      result.ok = resp.responseCode >= 200 && resp.responseCode < 400;
      if (resp.result !== undefined && resp.result !== null) {
        result.body = resp.result as string;
      }
      if (!result.ok) {
        result.error = `HTTP ${resp.responseCode}`;
      }
    } catch (e) {
      const err = e as BusinessError;
      result.error = `${err.code}: ${err.message}`;
      Log.e(TAG, `POST ${url} failed -> ${result.error}`);
    } finally {
      req.destroy();
    }
    return result;
  }

  /** application/json POST —— 少数解析接口要求 */
  static async postJson(url: string, json: string,
    headers?: Record<string, string>, timeoutMs: number = TIMEOUT_API): Promise<HttpResult> {
    const result: HttpResult = new HttpResult();
    const req = http.createHttp();
    try {
      const hdrs: Record<string, string> = HttpUtil.buildHeaders(headers);
      hdrs['Content-Type'] = 'application/json;charset=UTF-8';
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.POST,
        header: hdrs,
        extraData: json,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });
      result.status = resp.responseCode;
      result.ok = resp.responseCode >= 200 && resp.responseCode < 400;
      if (resp.result !== undefined && resp.result !== null) {
        result.body = resp.result as string;
      }
    } catch (e) {
      const err = e as BusinessError;
      result.error = `${err.code}: ${err.message}`;
      Log.e(TAG, `POST(json) ${url} failed -> ${result.error}`);
    } finally {
      req.destroy();
    }
    return result;
  }

  /** 不抛异常的 JSON 解析：影视源返回 HTML/垃圾数据是常态 */
  static parseJson<T>(text: string, tag: string): T | undefined {
    if (text === undefined || text.length === 0) {
      return undefined;
    }
    try {
      return JSON.parse(text) as T;
    } catch (e) {
      Log.w(TAG, `${tag} JSON.parse failed, head=${HttpUtil.head(text, 120)}`);
      return undefined;
    }
  }

  /** 去掉包在 JSON 外层的 xxxx(...) 回调壳 */
  static stripJsonp(text: string): string {
    let s: string = text.trim();
    const firstBrace: number = s.indexOf('{');
    const lastBrace: number = s.lastIndexOf('}');
    if (firstBrace > 0 && lastBrace > firstBrace) {
      s = s.substring(firstBrace, lastBrace + 1);
    }
    return s;
  }

  static head(text: string, n: number): string {
    if (text === undefined || text.length <= n) {
      return text;
    }
    return text.substring(0, n);
  }

  private static encodeForm(form: Record<string, string>): string {
    const keys: string[] = Object.keys(form);
    const parts: string[] = [];
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(form[k])}`);
    }
    return parts.join('&');
  }
}
