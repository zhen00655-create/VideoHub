import { display } from '@kit.ArkUI';
import { EpisodeModel, PlaySourceModel } from '../../../commons/models/TvBoxModels';
import { PlayRecord } from '../../../commons/models/PlayRecordModel';
import { AppTheme } from '../../../commons/theme/AppTheme';

/**
 * 选集面板（**右侧滑出**的集数网格）。
 *
 * 布局对齐主流影视 App 的「选集」抽屉：整条面板贴在屏幕右边、占满高度，
 * 里面是 5 列的等宽格子，每格一个集号；格子左上角可以挂一个小角标（本应用里是「已看」，
 * 对应参考图里 VIP / 收官礼 那一排小字）。
 *
 * ⚠️ 为什么是 CustomDialog 而不是页面内的浮层：
 *   面板要在**横屏播放页**和**详情页全屏**两处复用，做成对话框最省事 ——
 *   两个页面各自 `new CustomDialogController({ alignment: DialogAlignment.CenterEnd })`
 *   就能得到「贴右边」的效果，不用在每个页面的 Stack 里再插一套浮层。
 *
 * ⚠️ ArkTS 限制：CustomDialogController 的 builder 参数在**构造控制器时**求值，
 * 不随 @State 更新，所以父页在 sources 变化后必须重建控制器。
 */
@CustomDialog
export struct EpisodeDialog {
  controller?: CustomDialogController;

  /** 全部线路 */
  sources: PlaySourceModel[] = [];
  /** 当前线路 */
  currentSource: number = 0;
  /** 当前集 */
  currentEpisode: number = 0;
  /** 已看完集的位图（'1'=已看完），用于把看过的集标灰 + 挂「已看」角标 */
  watchedMask: string = '';
  /** 选择回调 */
  onPick: (sourceIndex: number, episodeIndex: number) => void = () => {
  };
  /**
   * 关闭回调：**必须由父页传入** `() => this.epCtrl?.close()`。
   *
   * ⚠️ 不要靠 `this.controller`（框架注入的那个）来关自己 —— 实测在
   * 「弹窗在页面的普通方法里 `new CustomDialogController` 创建」这种写法下，
   * 注入时机不保证，`controller` 可能是 undefined，表现就是**点 ✕ 完全没反应、
   * 弹窗关不掉**（用户 2026-10-12 反馈的问题 5）。走父页回调 100% 可靠。
   */
  onClose: () => void = () => {
  };

  @State activeSource: number = 0;
  @State reverse: boolean = false;
  /** 面板宽度（vp），进面板时按窗口方向算一次 */
  private panelW: number = 300;

  aboutToAppear(): void {
    this.activeSource = this.currentSource >= 0 && this.currentSource < this.sources.length
      ? this.currentSource : 0;
    this.panelW = this.panelWidth();
  }

  /**
   * 面板宽度：
   *  · 横屏（播放页 / 详情页全屏）—— 取窗口宽度的 42%（夹在 300~380），像参考资料那样只占右边一条；
   *  · 竖屏（详情页）—— 窗口本身窄，取 84% 才放得下 5 列。
   */
  private panelWidth(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const w: number = this.getUIContext().px2vp(d.width);
      const h: number = this.getUIContext().px2vp(d.height);
      if (w > h) {
        const wide: number = w * 0.42;
        return Math.min(380, wide < 300 ? 300 : wide);
      }
      const narrow: number = w * 0.84;
      return narrow < 272 ? 272 : narrow;
    } catch (e) {
      return 300;
    }
  }

  build() {
    Column() {
      /* ---------- 标题栏 ---------- */
      Row() {
        Text('选集')
          .fontSize(17)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .fontWeight(FontWeight.Medium)
        Text(this.titleSuffix())
          .fontSize(11)
          .fontColor(AppTheme.TEXT_TERTIARY)
          .margin({ left: 8 })
          .layoutWeight(1)
        Text(this.reverse ? '倒序' : '正序')
          .fontSize(11)
          .fontColor(AppTheme.TEXT_SECONDARY)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(AppTheme.CARD)
          .borderRadius(AppTheme.RADIUS_PILL)
          .onClick(() => {
            this.reverse = !this.reverse;
          })
        Text('✕')
          .fontSize(15)
          .fontColor(AppTheme.TEXT_SECONDARY)
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .margin({ left: 4 })
          .onClick(() => {
            this.close();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14, bottom: 10 })

      /* ---------- 线路切换 ---------- */
      if (this.sources.length > 1) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.sources, (s: PlaySourceModel, idx: number) => {
              Text(`${s.name}(${s.episodes.length})`)
                .fontSize(11)
                .fontColor(this.activeSource === idx ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
                .backgroundColor(this.activeSource === idx ? AppTheme.ACCENT : AppTheme.CARD)
                .padding({ left: 11, right: 11, top: 6, bottom: 6 })
                .borderRadius(AppTheme.RADIUS_PILL)
                .onClick(() => {
                  this.activeSource = idx;
                })
            }, (s: PlaySourceModel, idx: number) => `src_${idx}_${s.name}`)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
        .width('100%')
        .height(44)
      }

      /* ---------- 集数网格：5 列等宽，格子里是集号 + 可选角标 ---------- */
      Grid() {
        ForEach(this.episodes(), (ep: EpisodeModel) => {
          GridItem() {
            Column() {
              /* 角标行：固定 12 高，没有角标时也占位，保证所有集号竖直对齐 */
              Text(this.badgeOf(ep))
                .fontSize(9)
                .fontColor(AppTheme.GOLD)
                .height(12)
                .maxLines(1)
              Text(this.shortName(ep.name))
                .fontSize(13)
                .fontColor(this.epTextColor(ep))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .height(52)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.epBgColor(ep))
            .borderRadius(8)
            .onClick(() => {
              this.onPick(this.activeSource, ep.index);
              this.close();
            })
          }
        }, (ep: EpisodeModel) => `ep_${this.activeSource}_${this.reverse ? 1 : 0}_${ep.index}_${ep.name}_${this.isDone(ep) ? 1 : 0}`)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 20 })
      .scrollBar(BarState.Off)

      if (this.watchedCount() > 0) {
        Text(`已看 ${this.watchedCount()}/${this.episodes().length} 集`)
          .fontSize(10)
          .fontColor(AppTheme.TEXT_TERTIARY)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 14 })
      }
    }
    .width(this.panelW)
    .height('100%')
    .backgroundColor(AppTheme.SURFACE)
    .borderRadius({ topLeft: 16, bottomLeft: 16 })
  }

  /* ==================== 计算 ==================== */

  private close(): void {
    // 只走父页回调（原因见 onClose 的注释）
    this.onClose();
  }

  /** 当前线路的剧集表（倒序模式返回倒序副本） */
  private episodes(): EpisodeModel[] {
    if (this.activeSource < 0 || this.activeSource >= this.sources.length) {
      return [];
    }
    const list: EpisodeModel[] = this.sources[this.activeSource].episodes;
    return this.reverse ? list.slice().reverse() : list;
  }

  private titleSuffix(): string {
    if (this.activeSource >= 0 && this.activeSource < this.sources.length) {
      return `共 ${this.sources[this.activeSource].episodes.length} 集`;
    }
    return '';
  }

  /**
   * 格子里的短名。
   * 采集站的集名基本是「第01集」「第01集 高清版」这种，5 列格子放不下长串，
   * 把「第 / 集」这类固定字去掉只留序号，长名（如「周预告」）原样保留。
   */
  private shortName(name: string): string {
    if (name.length <= 3) {
      return name;
    }
    const m: string = name.replace('第', '').replace('集', '').trim();
    const isNum: boolean = m.length > 0 && !isNaN(Number(m));
    return isNum ? m : name;
  }

  private isCurrent(ep: EpisodeModel): boolean {
    return this.activeSource === this.currentSource && ep.index === this.currentEpisode;
  }

  /** 已看完（当前集不算，当前集优先高亮） */
  private isDone(ep: EpisodeModel): boolean {
    if (this.isCurrent(ep)) {
      return false;
    }
    return PlayRecord.isWatchedAt(this.watchedMask, ep.index);
  }

  /** 格子右上角的小角标：本应用里只有「已看」（参考图里对应 VIP / 收官礼 那一排小字） */
  private badgeOf(ep: EpisodeModel): string {
    return this.isDone(ep) ? '已看' : '';
  }

  private epTextColor(ep: EpisodeModel): string {
    if (this.isCurrent(ep)) {
      return '#FFFFFF';
    }
    if (this.isDone(ep)) {
      return AppTheme.EP_DONE_TEXT;
    }
    return AppTheme.TEXT_PRIMARY;
  }

  private epBgColor(ep: EpisodeModel): string {
    if (this.isCurrent(ep)) {
      return AppTheme.ACCENT;
    }
    return this.isDone(ep) ? AppTheme.EP_DONE_BG : 'rgba(255,255,255,0.08)';
  }

  private watchedCount(): number {
    let n: number = 0;
    const list: EpisodeModel[] = this.episodes();
    for (let i = 0; i < list.length; i++) {
      if (PlayRecord.isWatchedAt(this.watchedMask, list[i].index)) {
        n = n + 1;
      }
    }
    return n;
  }
}
