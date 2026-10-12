import { VodItem } from '../../../commons/models/TvBoxModels';
import { VodRow } from '../../../commons/models/RowModel';
import { PlayRecord } from '../../../commons/models/PlayRecordModel';
import { DetailParams, PlayerParams } from '../../../commons/models/RouteParams';
import { AppTheme } from '../../../commons/theme/AppTheme';
import { VodRowDataSource } from '../../../commons/datasource/BasicDataSource';
import { VodRowView } from '../../../commons/component/VodRowView';
import { VodEmptyView } from '../../../commons/component/LoadingView';
import { PlayDataStore } from '../../../commons/utils/PlayDataStore';
import { Log } from '../../../commons/utils/LogUtil';
import { ToastUtil } from '../../../commons/utils/ToastUtil';

const TAG = 'MinePage';
const PAD: number = AppTheme.PAGE_PADDING;
const GAP: number = 9;

@Component
export struct MinePage {
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  /** 播放页保存历史后 bump，回来时自动刷新 */
  @StorageProp('historyVersion') @Watch('onHistoryVersion') hisVersion: number = 0;
  /** 订阅主题版本：AppTheme 的 getter 不是响应式的，主题切换后靠它触发重渲染 */
  @StorageProp('themeVersion') themeVersion: number = 0;

  @State tab: number = 0;
  @State history: PlayRecord[] = [];
  @State favorites: PlayRecord[] = [];
  @State columns: number = 3;
  @State cardW: number = 110;
  @State posterH: number = 156;

  private favDs: VodRowDataSource = new VodRowDataSource();
  private innerW: number = 0;

  aboutToAppear(): void {
    this.loadAll();
  }

  onHistoryVersion(): void {
    this.loadAll();
  }

  build() {
    Column() {
      Row() {
        Text('我的')
          .fontSize(20)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Text('我的下载')
          .fontSize(12)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .backgroundColor(AppTheme.CARD)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .margin({ right: 8 })
          .onClick(() => {
            this.openDownloads();
          })
        Text('清空历史')
          .fontSize(12)
          .fontColor(AppTheme.TEXT_SECONDARY)
          .backgroundColor(AppTheme.CARD)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .onClick(() => {
            this.clearHistory();
          })
      }
      .width('100%')
      .padding({ left: PAD, right: PAD, top: 8, bottom: 6 })

      /* 分段 */
      Row({ space: 10 }) {
        Text(`播放历史 ${this.history.length}`)
          .fontSize(13)
          .fontColor(this.tab === 0 ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
          .backgroundColor(this.tab === 0 ? AppTheme.ACCENT : AppTheme.CARD)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .onClick(() => {
            this.tab = 0;
          })
        Text(`收藏 ${this.favorites.length}`)
          .fontSize(13)
          .fontColor(this.tab === 1 ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
          .backgroundColor(this.tab === 1 ? AppTheme.ACCENT : AppTheme.CARD)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .onClick(() => {
            this.tab = 1;
          })
        Blank()
     /*   Text('设置')
          .fontSize(12)
          .fontColor(AppTheme.TEXT_SECONDARY)
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'features/setting/view/SettingPage' }).catch(() => {
              ToastUtil.show(this.getUIContext(), '无法打开设置页');
            });
          })
        Text('源管理')
          .fontSize(12)
          .fontColor(AppTheme.TEXT_SECONDARY)
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'features/source/view/SourcePage' }).catch(() => {
              ToastUtil.show(this.getUIContext(), '无法打开源管理');
            });
          })*/
      }
      .width('100%')
      .padding({ left: PAD, right: PAD, bottom: 8 })

      List() {
        if (this.tab === 0) {
          if (this.history.length === 0) {
            ListItem() {
              VodEmptyView({
                text: '还没有观看记录',
                hint: '播放任意影片后会自动出现在这里，并记住续播进度'
              })
            }
          } else {
            ForEach(this.history, (r: PlayRecord) => {
              ListItem() {
                Row() {
                  Stack() {
                    Image(r.pic)
                      .alt($r('app.media.background'))
                      .width('100%')
                      .height('100%')
                      .objectFit(ImageFit.Cover)
                      .backgroundColor(AppTheme.PLACEHOLDER)
                  }
                  .width(74)
                  .height(100)
                  .borderRadius(8)
                  .clip(true)
                  .backgroundColor(AppTheme.PLACEHOLDER)

                  Column({ space: 6 }) {
                    Text(r.vodName)
                      .fontSize(14)
                      .fontColor(AppTheme.TEXT_PRIMARY)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text(this.episodeLine(r))
                      .fontSize(11)
                      .fontColor(AppTheme.TEXT_SECONDARY)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text(this.progressLine(r))
                      .fontSize(11)
                      .fontColor(AppTheme.TEXT_TERTIARY)
                      .width('100%')
                    if (r.watchedRatio() > 0) {
                      Stack({ alignContent: Alignment.Start }) {
                        Row()
                          .width('100%')
                          .height(3)
                          .backgroundColor(AppTheme.CARD)
                          .borderRadius(2)
                        Row()
                          .width(`${Math.round(r.watchedRatio() * 100)}%`)
                          .height(3)
                          .backgroundColor(AppTheme.ACCENT)
                          .borderRadius(2)
                      }
                      .width('100%')
                      .height(3)
                    }
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  .margin({ left: 12 })
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
                .onClick(() => {
                  this.resume(r);
                })
              }
              .padding({ bottom: 6 })
            }, (r: PlayRecord) => `his_${r.siteKey}_${r.vodId}_${r.updatedAt}`)
          }
        } else {
          if (this.favorites.length === 0) {
            ListItem() {
              VodEmptyView({
                text: '还没有收藏',
                hint: '在详情页点右上角「♡ 收藏」'
              })
            }
          } else {
            LazyForEach(this.favDs, (row: VodRow) => {
              ListItem() {
                VodRowView({
                  row: row,
                  cardW: this.cardW,
                  posterH: this.posterH,
                  gap: GAP,
                  onTap: (v: VodItem) => {
                    this.openDetail(v);
                  }
                })
              }
              .padding({ bottom: 12 })
            }, (row: VodRow) => row.key)
          }
        }

        ListItem() {
          Column() {
            Text('关于')
              .fontSize(12)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
              .margin({ bottom: 6 })
            Text('影视观 · HarmonyOS NEXT ArkTS\n'
              + '本应用本身不提供任何影视内容，仅作为第三方 JSON 配置源的通用客户端：\n'
              + '配置、解析规则与播放地址均来自用户自行添加的源。')
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .lineHeight(18)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 14, bottom: 30 })
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: PAD, right: PAD })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.onArea(newArea);
      })
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
    .padding({ top: this.getUIContext().px2vp(this.safeTopPx) })
  }

  /* ==================== 逻辑 ==================== */

  private async loadAll(): Promise<void> {
    try {
      this.history = await PlayDataStore.loadHistory();
      this.favorites = await PlayDataStore.loadFavorites();
      this.rebuildFavRows();
    } catch (e) {
      Log.e(TAG, `loadAll failed: ${e}`);
    }
  }

  private rebuildFavRows(): void {
    const items: VodItem[] = [];
    for (let i = 0; i < this.favorites.length; i++) {
      const r: PlayRecord = this.favorites[i];
      const v: VodItem = new VodItem();
      v.siteKey = r.siteKey;
      v.siteName = '';
      v.id = r.vodId;
      v.name = r.vodName;
      v.pic = r.pic;
      items.push(v);
    }
    this.favDs.setItems(VodRow.chunk(items, this.columns, `fav_${this.columns}`));
  }

  private onArea(area: Area): void {
    const w: number = area.width as number;
    if (w <= 10) {
      return;
    }
    const inner: number = w - PAD * 2;
    if (this.innerW > 0 && Math.abs(inner - this.innerW) < 2) {
      return;
    }
    this.innerW = inner;
    const cols: number = inner < 320 ? 2 : (inner < 600 ? 3 : (inner < 840 ? 4 : 5));
    const cardW: number = Math.floor((inner - GAP * (cols - 1)) / cols);
    this.columns = cols;
    this.cardW = cardW;
    this.posterH = Math.floor(cardW * 1.42);
    this.rebuildFavRows();
  }

  private resume(r: PlayRecord): void {
    const v: VodItem = new VodItem();
    v.siteKey = r.siteKey;
    v.id = r.vodId;
    v.name = r.vodName;
    v.pic = r.pic;
    const p: PlayerParams = new PlayerParams();
    p.vod = v;
    p.sourceIndex = r.sourceIndex;
    // 线路会被重排，带名字过去让播放页按名字对齐
    p.sourceName = r.sourceName;
    // 多集连播：本集看完就进下一集，没看完才回到本集原位置
    p.episodeIndex = PlayRecord.nextEpisodeIndex(r);
    p.positionMs = PlayRecord.resumeTargetMs(r);
    this.getUIContext().getRouter().pushUrl({ url: 'features/detail/view/VideoPlayerPage', params: p }).catch(() => {
      ToastUtil.show(this.getUIContext(), '无法打开播放器');
    });
  }

  private openDetail(v: VodItem): void {
    const p: DetailParams = new DetailParams();
    p.vod = v;
    this.getUIContext().getRouter().pushUrl({ url: 'features/detail/view/VideoDetailPage', params: p }).catch(() => {
      ToastUtil.show(this.getUIContext(), '无法打开详情页');
    });
  }

  private async clearHistory(): Promise<void> {
    await PlayDataStore.clearHistory();
    this.history = [];
  }

  /** 本地片库：列已下载文件 + 内置本地播放器 */
  private openDownloads(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'features/download/view/DownloadPage' }).catch(() => {
      ToastUtil.show(this.getUIContext(), '无法打开下载页');
    });
  }

  private episodeLine(r: PlayRecord): string {
    if (r.episodeName.length === 0) {
      return '尚未开始播放';
    }
    return r.finished ? `已看完 ${r.episodeName}` : `上次看到 ${r.episodeName}`;
  }

  /**
   * 聚合进度行：已看 3/24 集 · 12:30 / 45:00。
   * 单集看完但整部没完 → 显示「本集已看完」，全部看完 → 「全部看完」。
   */
  private progressLine(r: PlayRecord): string {
    const agg: string = r.episodeProgressText();
    const parts: string[] = [];
    if (agg.length > 0) {
      parts.push(agg);
    }
    if (r.finished) {
      parts.push(PlayRecord.allWatched(r) ? '全部看完' : '本集已看完');
    } else {
      parts.push(PlayRecord.progressText(r));
    }
    return parts.join(' · ');
  }
}
