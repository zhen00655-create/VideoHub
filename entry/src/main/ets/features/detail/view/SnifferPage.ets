import { webview } from '@kit.ArkWeb';
import { SnifferParams } from '../../../commons/models/RouteParams';
import { AppTheme } from '../../../commons/theme/AppTheme';
import { Log } from '../../../commons/utils/LogUtil';

const TAG = 'Sniffer';

/**
 * 网页嗅探兜底。
 *
 * 很多片源的 vod_play_url 指向的是一个 H5 播放页，直链藏在页面 JS 里，
 * 靠 HTTP 解析器拿不到。这里用隐藏 WebView 加载该页面，两条路同时找：
 *   1) onInterceptRequest —— 拦截页面自身发起的 .m3u8/.mp4 请求（最准）
 *   2) onPageEnd 后 runJavaScript 读 innerHTML，正则提取媒体地址（覆盖面更广）
 *
 * 找到后写进 AppStorage，播放页 onPageShow 读取并开播。
 */
@Entry
@Component
struct SnifferPage {
  /** 订阅主题版本：AppTheme 的 getter 不是响应式的，主题切换后靠它触发重渲染 */
  @StorageProp('themeVersion') themeVersion: number = 0;
  @State targetUrl: string = '';
  @State hint: string = '正在嗅探播放地址…';
  @State tried: number = 0;

  private controller: webview.WebviewController = new webview.WebviewController();
  /** 未做任何配置的响应对象 —— onInterceptRequest 返回它表示「不拦截，按原请求继续」 */
  private nonIntercept: WebResourceResponse = new WebResourceResponse();
  private got: boolean = false;
  private scanTimer: number = -1;

  aboutToAppear(): void {
    try {
      const raw: Object = this.getUIContext().getRouter().getParams();
      if (raw !== undefined && raw !== null) {
        const p: SnifferParams = raw as SnifferParams;
        this.targetUrl = p.targetUrl;
      }
    } catch (e) {
      Log.w(TAG, `readParams failed: ${e}`);
    }
    if (this.targetUrl.length === 0) {
      this.hint = '没有需要嗅探的地址';
    }
    // 兜底：页面加载完 4 秒还找不到就主动扫一次 DOM
    this.scanTimer = setTimeout(() => {
      this.scanDom();
    }, 4000);
  }

  aboutToDisappear(): void {
    if (this.scanTimer !== -1) {
      clearTimeout(this.scanTimer);
      this.scanTimer = -1;
    }
  }

  build() {
    Stack() {
      Web({ src: this.targetUrl, controller: this.controller })
        .onInterceptRequest((event) => {
          if (event) {
            const url: string = event.request.getRequestUrl();
            if (url !== undefined && SnifferPage.isMedia(url)) {
              this.onFound(url);
            }
          }
          // 返回一个未做任何设置的响应对象 => 按原网络请求继续加载
          return this.nonIntercept;
        })
        .onPageEnd(() => {
          this.tried = this.tried + 1;
          this.scanDom();
        })
        .onErrorReceive((event) => {
          if (event) {
            Log.w(TAG, `web error: ${event.error.getErrorInfo()}`);
          }
        })
        .width('100%')
        .height('100%')
        .opacity(0.06)

      Column({ space: 14 }) {
        if (this.got) {
          Text('✅')
            .fontSize(34)
          Text('已找到播放地址')
            .fontSize(15)
            .fontColor(AppTheme.TEXT_PRIMARY)
          Text('正在返回播放…')
            .fontSize(12)
            .fontColor(AppTheme.TEXT_TERTIARY)
        } else {
          LoadingProgress()
            .width(34)
            .height(34)
            .color(AppTheme.ACCENT)
          Text(this.hint)
            .fontSize(14)
            .fontColor(AppTheme.TEXT_PRIMARY)
          Text(`已扫描 ${this.tried} 次 · 目标页面 WebView 正在后台加载`)
            .fontSize(11)
            .fontColor(AppTheme.TEXT_TERTIARY)
            .textAlign(TextAlign.Center)
            .padding({ left: 30, right: 30 })

          Row({ space: 10 }) {
            Text('再扫一次')
              .fontSize(13)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .backgroundColor(AppTheme.CARD)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .borderRadius(AppTheme.RADIUS_PILL)
              .onClick(() => {
                this.scanDom();
              })
            Text('放弃')
              .fontSize(13)
              .fontColor('#FFFFFF')
              .backgroundColor(AppTheme.ACCENT)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .borderRadius(AppTheme.RADIUS_PILL)
              .onClick(() => {
                AppStorage.setOrCreate('sniff_result_url', '');
                this.getUIContext().getRouter().back();
              })
          }
          .margin({ top: 6 })
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor('rgba(13,15,20,0.86)')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.BG)
  }

  /* ==================== 嗅探逻辑 ==================== */

  private onFound(url: string): void {
    if (this.got) {
      return;
    }
    this.got = true;
    Log.i(TAG, `found media: ${url}`);
    if (this.scanTimer !== -1) {
      clearTimeout(this.scanTimer);
      this.scanTimer = -1;
    }
    AppStorage.setOrCreate('sniff_result_url', url);
    setTimeout(() => {
      this.getUIContext().getRouter().back();
    }, 260);
  }

  /** 读 DOM 找媒体地址 */
  private scanDom(): void {
    if (this.got) {
      return;
    }
    this.controller.runJavaScript('document.documentElement.innerHTML')
      .then((html: string) => {
        if (html !== undefined && html.length > 0) {
          const found: string = SnifferPage.extractMediaFromText(html);
          if (found.length > 0) {
            this.onFound(found);
            return;
          }
        }
        this.hint = '页面里暂时没找到 m3u8，正在等播放器加载…';
      })
      .catch((e: Error) => {
        Log.w(TAG, `runJavaScript failed: ${e.message}`);
      });
  }

  /** 从任意文本里提第一个媒体地址 */
  static extractMediaFromText(text: string): string {
    const patterns: string[] = [
      'https?://[^"\'\\\\\\s<>()]+?\\.m3u8[^"\'\\\\\\s<>()]*',
      'https?://[^"\'\\\\\\s<>()]+?\\.mp4[^"\'\\\\\\s<>()]*',
      'https?://[^"\'\\\\\\s<>()]+?\\.flv[^"\'\\\\\\s<>()]*',
      'https?://[^"\'\\\\\\s<>()]+?/index\\.m3u8[^"\'\\\\\\s<>()]*'
    ];
    for (let i = 0; i < patterns.length; i++) {
      const re = new RegExp(patterns[i], 'i');
      const m = re.exec(text);
      if (m !== null && m.length > 0 && m[0].length > 12) {
        return m[0].replace(/\\u002F/gi, '/').replace(/\\\//g, '/');
      }
    }
    return '';
  }

  static isMedia(url: string): boolean {
    const u: string = url.toLowerCase();
    return u.indexOf('.m3u8') >= 0 || u.indexOf('.mp4') >= 0
      || u.indexOf('.flv') >= 0 || u.indexOf('.ts?') >= 0;
  }
}
