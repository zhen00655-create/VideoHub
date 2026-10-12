import { EpisodeModel } from '../../../commons/models/TvBoxModels';
import { AppTheme } from '../../../commons/theme/AppTheme';

/**
 * 下载选择弹窗：**全部剧集** 或 **指定剧集**（多选）。
 *
 * 交互（对齐参考图的「集数网格」手感）：
 *   · 默认「全部剧集」—— 所有格子呈选中态，直接点「开始下载」就是整部剧；
 *   · 点任意一格 → 自动切到「指定剧集」，只留刚点的那一集（想排除个别集时最省事）；
 *   · 再点就逐格增删，配合「全选 / 清空」批量操作。
 *
 * 真正下载的活由父页做（解析直链 → DownloadUtil.enqueue），本弹窗只负责选。
 */
@CustomDialog
export struct DownloadDialog {
  controller?: CustomDialogController;

  /** 当前线路的剧集表 */
  episodes: EpisodeModel[] = [];
  /** 正在播的那一集（进面板时默认勾上，方便「从这集往后下」） */
  currentEpisode: number = 0;
  /** 确认回调：all=true 时 indices 无意义 */
  onConfirm: (all: boolean, indices: number[]) => void = () => {
  };
  /**
   * 关闭回调：**必须由父页传入** `() => this.downloadCtrl?.close()`。
   * ⚠️ 理由同 `EpisodeDialog.onClose` —— 靠框架注入的 `controller` 关自己不可靠，
   * 表现就是「点 ✕ 关不掉」（用户 2026-10-12 反馈的问题 4）。
   */
  onClose: () => void = () => {
  };

  /** 是否「全部剧集」 */
  @State all: boolean = true;
  /** 勾选位图（'1'=选中），长度与 episodes 一致 */
  @State selMask: string = '';

  aboutToAppear(): void {
    // 初始勾选：只有当前这一集，用户点「指定」时不用从零开始
    this.selMask = this.zeros();
  }

  build() {
    Column() {
      /* ---------- 标题栏 ---------- */
      Row() {
        Text('下载')
          .fontSize(17)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .fontWeight(FontWeight.Medium)
        Text(this.summary())
          .fontSize(11)
          .fontColor(AppTheme.TEXT_TERTIARY)
          .margin({ left: 8 })
          .layoutWeight(1)
        Text('✕')
          .fontSize(15)
          .fontColor(AppTheme.TEXT_SECONDARY)
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.close();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14, bottom: 8 })

      /* ---------- 范围切换 ---------- */
      Row({ space: 8 }) {
        Text(`全部剧集(${this.episodes.length})`)
          .fontSize(12)
          .fontColor(this.all ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
          .backgroundColor(this.all ? AppTheme.ACCENT : AppTheme.CARD)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .onClick(() => {
            this.all = true;
          })
        Text('指定剧集')
          .fontSize(12)
          .fontColor(this.all ? AppTheme.TEXT_SECONDARY : '#FFFFFF')
          .backgroundColor(this.all ? AppTheme.CARD : AppTheme.ACCENT)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .onClick(() => {
            this.all = false;
            if (this.countSel() === 0) {
              this.selMask = this.setAt(this.zeros(), this.currentEpisode, true);
            }
          })
        Blank()
        if (!this.all) {
          Text('全选')
            .fontSize(12)
            .fontColor(AppTheme.TEXT_SECONDARY)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(AppTheme.CARD)
            .borderRadius(AppTheme.RADIUS_PILL)
            .onClick(() => {
              this.selMask = this.fill('1');
            })
          Text('清空')
            .fontSize(12)
            .fontColor(AppTheme.TEXT_SECONDARY)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(AppTheme.CARD)
            .borderRadius(AppTheme.RADIUS_PILL)
            .onClick(() => {
              this.selMask = this.zeros();
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      /* ---------- 集数网格 ---------- */
      Grid() {
        ForEach(this.episodes, (ep: EpisodeModel) => {
          GridItem() {
            Text(this.shortName(ep.name))
              .fontSize(13)
              .fontColor(this.isSel(ep.index) ? '#FFFFFF' : AppTheme.TEXT_PRIMARY)
              .textAlign(TextAlign.Center)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .height(44)
              .backgroundColor(this.isSel(ep.index) ? AppTheme.ACCENT : AppTheme.CARD)
              .borderRadius(8)
              .onClick(() => {
                this.toggle(ep.index);
              })
          }
        }, (ep: EpisodeModel) => `dl_${ep.index}_${ep.name}_${this.isSel(ep.index) ? 1 : 0}`)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      .scrollBar(BarState.Off)

      Text('下载到应用私有空间（不会被系统清理），可在「我的 → 我的下载」里播放或删除；m3u8 直链只能存到播放列表')
        .fontSize(10)
        .fontColor(AppTheme.TEXT_TERTIARY)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

      /* ---------- 开始下载 ---------- */
      Row() {
        Text(this.countSel() > 0 ? `开始下载（${this.countSel()} 集）` : '请至少选一集')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 11, bottom: 11 })
          .backgroundColor(this.countSel() > 0 ? AppTheme.ACCENT : AppTheme.CARD)
          .borderRadius(AppTheme.RADIUS_PILL)
          .onClick(() => {
            if (this.countSel() <= 0) {
              return;
            }
            const allMode: boolean = this.all;
            const picked: number[] = allMode ? [] : this.selectedIndices();
            this.close();
            this.onConfirm(allMode, picked);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 18 })
    }
    .width('100%')
    .height('70%')
    .backgroundColor(AppTheme.SURFACE)
    .borderRadius({ topLeft: 18, topRight: 18 })
  }

  /* ==================== 计算 ==================== */

  private close(): void {
    // 只走父页回调（原因见 onClose 的注释）
    this.onClose();
  }

  private summary(): string {
    if (this.all) {
      return `共 ${this.episodes.length} 集`;
    }
    return `已选 ${this.countSel()} 集`;
  }

  private isSel(index: number): boolean {
    if (this.all) {
      return true;
    }
    return this.selMask.charAt(index) === '1';
  }

  private countSel(): number {
    if (this.all) {
      return this.episodes.length;
    }
    let n: number = 0;
    for (let i = 0; i < this.episodes.length; i++) {
      if (this.selMask.charAt(i) === '1') {
        n = n + 1;
      }
    }
    return n;
  }

  private selectedIndices(): number[] {
    const out: number[] = [];
    for (let i = 0; i < this.episodes.length; i++) {
      if (this.selMask.charAt(i) === '1') {
        out.push(this.episodes[i].index);
      }
    }
    return out;
  }

  private toggle(index: number): void {
    if (this.all) {
      // 从「全部」点某一集：切成指定模式，只留这一集（想排除个别集时最省事）
      this.all = false;
      this.selMask = this.setAt(this.zeros(), index, true);
      return;
    }
    this.selMask = this.setAt(this.selMask, index, this.selMask.charAt(index) !== '1');
  }

  /* ---------- 位图（字符串）小工具 ---------- */

  private zeros(): string {
    return this.fill('0');
  }

  private fill(ch: string): string {
    let s: string = '';
    for (let i = 0; i < this.episodes.length; i++) {
      s = s + ch;
    }
    return s;
  }

  private setAt(src: string, index: number, on: boolean): string {
    if (index < 0 || index >= this.episodes.length) {
      return src;
    }
    const base: string = src.length === this.episodes.length ? src : this.zeros();
    return `${base.substring(0, index)}${on ? '1' : '0'}${base.substring(index + 1)}`;
  }

  /** 去掉「第/集」这类固定字，只留序号（和选集面板保持一致） */
  private shortName(name: string): string {
    if (name.length <= 3) {
      return name;
    }
    const m: string = name.replace('第', '').replace('集', '').trim();
    const isNum: boolean = m.length > 0 && !isNaN(Number(m));
    return isNum ? m : name;
  }
}
