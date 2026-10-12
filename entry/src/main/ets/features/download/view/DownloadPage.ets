import { common } from '@kit.AbilityKit';
import { AppTheme } from '../../../commons/theme/AppTheme';
import { VodEmptyView } from '../../../commons/component/LoadingView';
import { DownloadItem, DownloadUtil } from '../../../commons/utils/DownloadUtil';
import { LocalVideoPlayer } from '../component/LocalVideoPlayer';
import { Log } from '../../../commons/utils/LogUtil';
import { ToastUtil } from '../../../commons/utils/ToastUtil';

const TAG = 'DownloadPage';
const PAD: number = AppTheme.PAGE_PADDING;

/**
 * 「我的下载」—— 本地片库。
 *
 * 只干三件事：列出来、点开看、删掉。
 * 播放交给 `LocalVideoPlayer`（本地文件不走在线那套解析链路，见该文件说明）。
 *
 * ⚠️ 下载目录是 `<filesDir>/vod_download`（应用私有**持久**目录），不是 cacheDir ——
 *   cacheDir 会被系统在空间紧张时清掉，用户「下载好的片子过几天没了」就是这么来的。
 */
@Entry
@Component
struct DownloadPage {
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;
  /** 订阅主题版本：AppTheme 的 getter 不是响应式的，主题切换后靠它触发重渲染 */
  @StorageProp('themeVersion') themeVersion: number = 0;

  @State items: DownloadItem[] = [];
  @State loading: boolean = true;
  /** 正在播放的文件绝对路径；空串表示不播 */
  @State playingPath: string = '';
  @State playingTitle: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  onPageShow(): void {
    // 从别处回来（比如刚下完）要看到最新的列表
    this.reload();
  }

  /** 播放中先关播放器，再退页面 —— 否则会把整页一起关掉 */
  onBackPress(): boolean {
    if (this.playingPath.length > 0) {
      this.playingPath = '';
      return true;
    }
    this.getUIContext().getRouter().back();
    return true;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        /* ---------- 标题栏 ---------- */
        Row() {
          Text('‹')
            .fontSize(26)
            .fontColor(AppTheme.TEXT_PRIMARY)
            .width(38)
            .height(38)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })
          Column({ space: 2 }) {
            Text('我的下载')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.TEXT_PRIMARY)
            Text(this.summary())
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 4 })
          .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)

          if (this.items.length > 0) {
            Text('全部删除')
              .fontSize(12)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .backgroundColor(AppTheme.CARD)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(AppTheme.RADIUS_PILL)
              .onClick(() => {
                this.clearAll();
              })
          }
        }
        .width('100%')
        .padding({ left: PAD - 6, right: PAD, top: 6, bottom: 8 })

        /* ---------- 列表 ---------- */
        List({ space: 10 }) {
          if (this.loading) {
            ListItem() {
              VodEmptyView({ text: '正在读取本地文件…', hint: '下载目录：应用私有空间/vod_download' })
            }
          } else if (this.items.length === 0) {
            ListItem() {
              VodEmptyView({
                text: '还没有下载任何视频',
                hint: '在详情页小窗点「下载」图标，可以选全部剧集或指定集数'
              })
            }
          } else {
            ForEach(this.items, (it: DownloadItem) => {
              ListItem() {
                this.itemRow(it)
              }
            }, (it: DownloadItem) => `dl_${it.path}_${it.mtimeMs}`)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: PAD, right: PAD })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.getUIContext().px2vp(this.safeTopPx) })

      /* ---------- 本地播放器（全屏浮层） ---------- */
      if (this.playingPath.length > 0) {
        LocalVideoPlayer({
          path: this.playingPath,
          title: this.playingTitle,
          onClose: () => {
            this.playingPath = '';
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [
        [AppTheme.BG_GRAD_TOP, 0.0],
        [AppTheme.BG_GRAD_MID, 0.5],
        [AppTheme.BG_GRAD_BOTTOM, 1.0]
      ]
    })
  }

  /** 一行：片名 / 集名 / 体积 · 时间，右侧「播放」+「删除」 */
  @Builder
  itemRow(it: DownloadItem) {
    Column({ space: 8 }) {
      Row() {
        Column({ space: 4 }) {
          Text(it.vodName.length > 0 ? it.vodName : it.name)
            .fontSize(15)
            .fontColor(AppTheme.TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
          Text(this.subLine(it))
            .fontSize(11)
            .fontColor(AppTheme.TEXT_TERTIARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .hitTestBehavior(HitTestMode.None)

        Row({ space: 8 }) {
          Text('播放')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .backgroundColor(AppTheme.ACCENT)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(AppTheme.RADIUS_PILL)
            .onClick(() => {
              this.play(it);
            })
          Text('删除')
            .fontSize(12)
            .fontColor(AppTheme.TEXT_SECONDARY)
            .backgroundColor(AppTheme.CARD)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(AppTheme.RADIUS_PILL)
            .onClick(() => {
              this.removeOne(it);
            })
        }
        .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')

      if (it.isPlaylist) {
        Text('这是一个 HLS 播放列表（.m3u8），只能下到列表本身，可能无法完整离线播放')
          .fontSize(10)
          .fontColor(AppTheme.GOLD)
          .width('100%')
          .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(AppTheme.CARD)
    .borderRadius(12)
  }

  /* ==================== 逻辑 ==================== */

  private async reload(): Promise<void> {
    const ctx = this.ctx();
    if (ctx === undefined) {
      this.loading = false;
      return;
    }
    try {
      this.items = await DownloadUtil.list(ctx);
    } catch (e) {
      Log.e(TAG, `reload failed: ${e}`);
      this.items = [];
    }
    this.loading = false;
  }

  private ctx(): common.UIAbilityContext | undefined {
    const c = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return (c === undefined || c === null) ? undefined : c;
  }

  private play(it: DownloadItem): void {
    if (it.isPlaylist) {
      ToastUtil.show(this.getUIContext(), 'm3u8 播放列表无法本地播放');
      return;
    }
    this.playingTitle = it.epName.length > 0 ? `${it.vodName} · ${it.epName}` : it.vodName;
    this.playingPath = it.path;
  }

  private async removeOne(it: DownloadItem): Promise<void> {
    const ok: boolean = await DownloadUtil.remove(it.path);
    ToastUtil.show(this.getUIContext(), ok ? '已删除' : '删除失败');
    if (ok) {
      this.reload();
    }
  }

  private async clearAll(): Promise<void> {
    const ctx = this.ctx();
    if (ctx === undefined) {
      return;
    }
    const n: number = await DownloadUtil.clearAll(ctx);
    ToastUtil.show(this.getUIContext(), `已删除 ${n} 个文件`);
    this.reload();
  }

  private summary(): string {
    if (this.items.length === 0) {
      return '应用私有空间 · 不会被系统清理';
    }
    let total: number = 0;
    for (let i = 0; i < this.items.length; i++) {
      total = total + this.items[i].size;
    }
    return `共 ${this.items.length} 个 · ${DownloadUtil.sizeText(total)}`;
  }

  private subLine(it: DownloadItem): string {
    const ep: string = it.epName.length > 0 ? `${it.epName} · ` : '';
    return `${ep}${DownloadUtil.sizeText(it.size)} · ${DownloadPage.stamp(it.mtimeMs)}`;
  }

  /** 时间戳 → `MM-dd HH:mm`。不用 padStart（ArkTS 支持但没必要赌），手工补零 */
  private static stamp(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    const d: Date = new Date(ms);
    const mo: number = d.getMonth() + 1;
    const day: number = d.getDate();
    const h: number = d.getHours();
    const mi: number = d.getMinutes();
    const p2 = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${p2(mo)}-${p2(day)} ${p2(h)}:${p2(mi)}`;
  }
}
