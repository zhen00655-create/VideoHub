import { common } from '@kit.AbilityKit';
import { SiteModel, VodItem } from '../../../commons/models/TvBoxModels';
import { VodRow } from '../../../commons/models/RowModel';
import { DetailParams } from '../../../commons/models/RouteParams';
import { ConfigManager } from '../../source/ConfigLoader';
import { SiteRouter } from '../../source/SiteRouter';
import { AppTheme } from '../../../commons/theme/AppTheme';
import { VodRowDataSource } from '../../../commons/datasource/BasicDataSource';
import { VodRowView } from '../../../commons/component/VodRowView';
import { VodEmptyView } from '../../../commons/component/LoadingView';
import { Store } from '../../../commons/utils/StoreUtil';
import { Log } from '../../../commons/utils/LogUtil';
import { ToastUtil } from '../../../commons/utils/ToastUtil';

const TAG = 'SearchPage';
const PAD: number = AppTheme.PAGE_PADDING;
const GAP: number = 9;
const KEY_SEARCH_HISTORY: string = 'search_history';

/**
 * 同一部片在多个源都有时的来源选择弹窗。
 * 只在自定义弹窗里放一个 List，避免用系统 ActionSheet（各版本 API 差异较大）。
 */
@CustomDialog
struct SourcePickDialog {
  controller?: CustomDialogController;
  title: string = '';
  items: VodItem[] = [];
  onPick: (v: VodItem) => void = () => {
  };
  /** 关闭回调：由父页传入（不靠框架注入的 controller，理由同 EpisodeDialog.onClose） */
  onClose: () => void = () => {
  };

  build() {
    Column() {
      Text('选择播放来源')
        .fontSize(16)
        .fontColor(AppTheme.TEXT_PRIMARY)
        .fontWeight(FontWeight.Medium)
        .width('100%')
      Text(this.title)
        .fontSize(12)
        .fontColor(AppTheme.TEXT_TERTIARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 4, bottom: 10 })

      List({ space: 8 }) {
        ForEach(this.items, (v: VodItem) => {
          ListItem() {
            Row() {
              Column({ space: 3 }) {
                Text(v.siteName.length > 0 ? v.siteName : v.siteKey)
                  .fontSize(14)
                  .fontColor(AppTheme.TEXT_PRIMARY)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(v.remarks.length > 0 ? v.remarks : '点击使用该来源')
                  .fontSize(11)
                  .fontColor(AppTheme.TEXT_TERTIARY)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text('›')
                .fontSize(18)
                .fontColor(AppTheme.TEXT_TERTIARY)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(AppTheme.CARD)
            .borderRadius(10)
            .onClick(() => {
              this.onClose();
              this.onPick(v);
            })
          }
        }, (v: VodItem) => `sp_${v.siteKey}_${v.id}`)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('52%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .backgroundColor(AppTheme.SURFACE)
    .borderRadius({ topLeft: 18, topRight: 18 })
  }
}

/**
 * 搜索页：独立路由页（登记在 main_pages.json），由首页顶部搜索按钮 pushUrl 进入。
 * 必须是 @Entry，否则 router 跳不过来。
 */
@Entry
@Component
struct SearchPage {
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  /** 独立页没有底部页签栏挡着，底部安全区要自己让 */
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;
  /** 订阅主题版本：AppTheme 的 getter 不是响应式的，主题切换后靠它触发重渲染 */
  @StorageProp('themeVersion') themeVersion: number = 0;

  @State keyword: string = '';
  @State results: VodItem[] = [];
  @State searching: boolean = false;
  @State searched: boolean = false;
  @State errMsg: string = '';
  @State history: string[] = [];
  @State columns: number = 3;
  @State cardW: number = 110;
  @State posterH: number = 156;
  /** 精确模式：客户端二次过滤，只保留片名包含完整关键词的结果 */
  @State exactMode: boolean = false;

  private rowDs: VodRowDataSource = new VodRowDataSource();
  private innerW: number = 0;
  private reqSeq: number = 0;
  /** 片名 → 同名的全部来源，点击卡片时用来弹来源选择 */
  private groupMap: Map<string, VodItem[]> = new Map<string, VodItem[]>();

  aboutToAppear(): void {
    this.loadHistory();
  }

  build() {
    Column() {
      /* 返回栏 + 搜索框 */
      Row({ space: 8 }) {
        Text('‹')
          .fontSize(28)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .width(30)
          .height(38)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })
        Row({ space: 6 }) {
          Text('🔍')
            .fontSize(14)
          TextInput({ placeholder: '搜影片 / 剧集 / 综艺 / 动漫', text: this.keyword })
            .placeholderColor(AppTheme.TEXT_TERTIARY)
            .fontColor(AppTheme.TEXT_PRIMARY)
            .fontSize(14)
            .backgroundColor('#00000000')
            .padding(0)
            .layoutWeight(1)
            .height(38)
            // 作为独立搜索页进入，直接给焦点，省一次点击
            .defaultFocus(true)
            .onChange((v: string) => {
              this.keyword = v;
            })
            .onSubmit(() => {
              this.doSearch();
            })
        }
        .layoutWeight(1)
        .height(38)
        .padding({ left: 10, right: 10 })
        .backgroundColor(AppTheme.CARD)
        .borderRadius(19)

        Text(this.searching ? '搜索中' : '搜索')
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor(this.searching ? AppTheme.TEXT_TERTIARY : AppTheme.ACCENT)
          .padding({ left: 16, right: 16, top: 9, bottom: 9 })
          .borderRadius(19)
          .onClick(() => {
            this.doSearch();
          })
      }
      .width('100%')
      .padding({ left: PAD, right: PAD, top: 10, bottom: 8 })

      /* 搜索模式 */
      Row({ space: 8 }) {
        Text('模糊匹配')
          .fontSize(12)
          .fontColor(!this.exactMode ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
          .backgroundColor(!this.exactMode ? AppTheme.ACCENT : AppTheme.CARD)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .onClick(() => {
            this.exactMode = false;
          })
        Text('精确匹配')
          .fontSize(12)
          .fontColor(this.exactMode ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
          .backgroundColor(this.exactMode ? AppTheme.ACCENT : AppTheme.CARD)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .onClick(() => {
            this.exactMode = true;
          })
        Text('同名结果已按来源聚合，点击卡片可换源')
          .fontSize(10)
          .fontColor(AppTheme.TEXT_TERTIARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: PAD, right: PAD, bottom: 8 })

      /* 搜索历史 */
      if (!this.searched && this.history.length > 0) {
        Column() {
          Row() {
            Text('搜索历史')
              .fontSize(12)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .layoutWeight(1)
            Text('清空')
              .fontSize(12)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .onClick(() => {
                this.clearHistory();
              })
          }
          .width('100%')
          .margin({ bottom: 8 })

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.history, (h: string) => {
              Text(h)
                .fontSize(12)
                .fontColor(AppTheme.TEXT_SECONDARY)
                .backgroundColor(AppTheme.CARD)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(AppTheme.RADIUS_PILL)
                .margin({ right: 8, bottom: 8 })
                .onClick(() => {
                  this.keyword = h;
                  this.doSearch();
                })
            }, (h: string) => `his_${h}`)
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: PAD, right: PAD, top: 4 })
        .alignItems(HorizontalAlign.Start)
      }

      /* 结果 */
      List() {
        if (this.searching && this.results.length === 0) {
          ListItem() {
            Column({ space: 12 }) {
              LoadingProgress()
                .width(30)
                .height(30)
                .color(AppTheme.ACCENT)
              Text(`正在 ${this.siteCount()} 个资源站中检索…`)
                .fontSize(12)
                .fontColor(AppTheme.TEXT_TERTIARY)
            }
            .width('100%')
            .height(160)
            .justifyContent(FlexAlign.Center)
          }
        } else if (this.results.length === 0) {
          ListItem() {
            VodEmptyView({
              text: this.searched ? '没有找到相关影片' : '输入关键词开始搜索',
              hint: this.searched
                ? (this.errMsg.length > 0 ? this.errMsg : '试试更短的关键词，或到「源管理」添加更多 type:1 采集站')
                : '会在所有可用资源站里并发检索'
            })
          }
        } else {
          LazyForEach(this.rowDs, (row: VodRow) => {
            ListItem() {
              VodRowView({
                row: row,
                cardW: this.cardW,
                posterH: this.posterH,
                gap: GAP,
                preferSiteName: true,
                onTap: (v: VodItem) => {
                  this.openDetail(v);
                }
              })
            }
            .padding({ bottom: 12 })
          }, (row: VodRow) => row.key)

          ListItem() {
            Text(`共 ${this.results.length} 条结果`)
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 20 })
          }
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
    .padding({
      top: this.getUIContext().px2vp(this.safeTopPx),
      bottom: this.getUIContext().px2vp(this.safeBottomPx)
    })
  }

  /* ==================== 逻辑 ==================== */

  private async doSearch(): Promise<void> {
    const wd: string = this.keyword.trim();
    if (wd.length === 0) {
      this.errMsg = '请输入关键词';
      return;
    }
    if (this.searching) {
      return;
    }

    this.reqSeq = this.reqSeq + 1;
    const seq: number = this.reqSeq;
    this.searching = true;
    this.searched = true;
    this.results = [];
    this.rebuildRows();
    this.errMsg = '';

    let sites: SiteModel[] = ConfigManager.get().sites;
    if (sites.length === 0) {
      try {
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        await ConfigManager.get().ensureInit(ctx);
        sites = ConfigManager.get().sites;
      } catch (e) {
        Log.w(TAG, `ensureInit failed: ${e}`);
      }
    }

    let found: VodItem[] = [];
    try {
      found = await SiteRouter.searchAll(sites, wd, 1);
    } catch (e) {
      this.errMsg = `搜索异常: ${e}`;
    }

    if (seq !== this.reqSeq) {
      // 已经有更新的搜索请求，丢弃本次结果
      return;
    }

    this.searching = false;
    const filtered: VodItem[] = this.exactMode ? SearchPage.filterExact(found, wd) : found;
    const grouped: VodItem[] = this.groupResults(filtered);
    this.results = grouped;
    this.rebuildRows();
    if (grouped.length > 0) {
      this.pushHistory(wd);
    } else if (found.length > 0 && this.exactMode) {
      this.errMsg = `找到 ${found.length} 条结果，但没有片名精确包含「${wd}」的，试试模糊匹配`;
    } else if (this.errMsg.length === 0) {
      this.errMsg = '所有源都没有返回结果（部分源可能已失效）';
    }
    Log.i(TAG, `search "${wd}" -> raw=${found.length} exact=${this.exactMode} grouped=${grouped.length}`);
  }

  /**
   * 精确匹配过滤。
   * MacCMS 的关键词搜索是 LIKE，返回里常混进不相关条目；
   * 精确模式只保留「片名（去掉空白）里包含完整关键词」的结果。
   */
  private static filterExact(list: VodItem[], keyword: string): VodItem[] {
    const k: string = SearchPage.nameKey(keyword);
    if (k.length === 0) {
      return list;
    }
    const out: VodItem[] = [];
    for (let i = 0; i < list.length; i++) {
      if (SearchPage.nameKey(list[i].name).indexOf(k) >= 0) {
        out.push(list[i]);
      }
    }
    return out;
  }

  /**
   * 多源聚合：同名影片只保留一张卡片，来源汇总写在 siteName 上（如「非凡资源 等 3 个源」），
   * 点击卡片时再从 groupMap 里取出全部来源让用户挑。
   */
  private groupResults(list: VodItem[]): VodItem[] {
    this.groupMap = new Map<string, VodItem[]>();
    const out: VodItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const v: VodItem = list[i];
      const key: string = SearchPage.nameKey(v.name);
      if (key.length === 0) {
        out.push(v);
        continue;
      }
      const exist: VodItem[] | undefined = this.groupMap.get(key);
      if (exist === undefined) {
        this.groupMap.set(key, [v]);
        // 代表条目：字段照抄，siteName 稍后汇总
        const rep: VodItem = new VodItem();
        rep.siteKey = v.siteKey;
        rep.siteName = v.siteName;
        rep.id = v.id;
        rep.name = v.name;
        rep.pic = v.pic;
        rep.remarks = v.remarks;
        rep.year = v.year;
        rep.area = v.area;
        rep.typeName = v.typeName;
        rep.score = v.score;
        rep.content = v.content;
        out.push(rep);
      } else {
        exist.push(v);
      }
    }
    for (let i = 0; i < out.length; i++) {
      const g: VodItem[] | undefined = this.groupMap.get(SearchPage.nameKey(out[i].name));
      if (g !== undefined && g.length > 1) {
        const first: string = g[0].siteName.length > 0 ? g[0].siteName : g[0].siteKey;
        out[i].siteName = `${first} 等 ${g.length} 个源`;
      }
    }
    return out;
  }

  /** 片名归一化：去掉空白（含全角空格）并转小写，用于同名归并 */
  private static nameKey(name: string): string {
    let s: string = '';
    for (let i = 0; i < name.length; i++) {
      const c: string = name.charAt(i);
      if (c !== ' ' && c !== '\t' && c !== '\u3000' && c !== '\n') {
        s = `${s}${c}`;
      }
    }
    return s.toLowerCase();
  }

  private rebuildRows(): void {
    const rows: VodRow[] = VodRow.chunk(this.results, this.columns,
      `s_${this.keyword}_${this.exactMode ? 1 : 0}_${this.columns}`);
    this.rowDs.setItems(rows);
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
    this.rebuildRows();
  }

  private siteCount(): number {
    return ConfigManager.get().sites.length;
  }

  /** 有多个来源时先让用户选源，只有一个就直接进详情 */
  private openDetail(v: VodItem): void {
    const group: VodItem[] | undefined = this.groupMap.get(SearchPage.nameKey(v.name));
    if (group !== undefined && group.length > 1) {
      this.showSourcePick(v.name, group);
      return;
    }
    this.gotoDetail(v);
  }

  private showSourcePick(title: string, group: VodItem[]): void {
    const ctrl: CustomDialogController = new CustomDialogController({
      builder: SourcePickDialog({
        title: title,
        items: group.slice(),
        onPick: (v: VodItem) => {
          this.gotoDetail(v);
        },
        onClose: () => {
          ctrl.close();
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true
    });
    ctrl.open();
  }

  private gotoDetail(v: VodItem): void {
    const p: DetailParams = new DetailParams();
    p.vod = v;
    this.getUIContext().getRouter().pushUrl({ url: 'features/detail/view/VideoDetailPage', params: p }).catch(() => {
      ToastUtil.show(this.getUIContext(), '无法打开详情页');
    });
  }

  /* 搜索历史（最多 12 条） */

  private async loadHistory(): Promise<void> {
    this.history = await Store.getStringArray(KEY_SEARCH_HISTORY, []);
  }

  private async pushHistory(wd: string): Promise<void> {
    const next: string[] = [wd];
    for (let i = 0; i < this.history.length && next.length < 12; i++) {
      if (this.history[i] !== wd) {
        next.push(this.history[i]);
      }
    }
    this.history = next;
    await Store.putStringArray(KEY_SEARCH_HISTORY, next);
  }

  private async clearHistory(): Promise<void> {
    this.history = [];
    await Store.putStringArray(KEY_SEARCH_HISTORY, []);
  }
}
