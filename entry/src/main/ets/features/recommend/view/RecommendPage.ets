import { common } from '@kit.AbilityKit';
import { ClassModel, SiteModel, VodItem } from '../../../commons/models/TvBoxModels';
import { VodRow } from '../../../commons/models/RowModel';
import { DetailParams } from '../../../commons/models/RouteParams';
import { ConfigManager } from '../../source/ConfigLoader';
import { ProbeResult, SiteProbe } from '../../source/SiteProbe';
import { SiteRouter, VodPage } from '../../source/SiteRouter';
import { AppTheme } from '../../../commons/theme/AppTheme';
import { VodRowDataSource } from '../../../commons/datasource/BasicDataSource';
import { VodRowView } from '../../../commons/component/VodRowView';
import { VodRail } from '../../../commons/component/VodRail';
import { VodEmptyView, VodListSkeleton } from '../../../commons/component/LoadingView';
import { Log } from '../../../commons/utils/LogUtil';
import { ToastUtil } from '../../../commons/utils/ToastUtil';

const TAG = 'RecommendPage';
const PAD: number = AppTheme.PAGE_PADDING;
const GAP: number = 9;

/** 轮播取「最近更新」前 6 条（必须有图，否则整块留白） */
const BANNER_COUNT: number = 6;
const BANNER_H: number = 172;
/** 每条导轨最多试几个 type_id：容器分类常常查不到内容，要顺着站点的分类顺序往下钻 */
const RAIL_CANDIDATES: number = 3;
/** 导轨一次放多少条 */
const RAIL_LIMIT: number = 12;

/** 导轨类型 */
const KIND_MOVIE: number = 0;
const KIND_TV: number = 1;

/**
 * 推荐页。
 *
 * 底部页签的第二格（原「直播」的位置）。原来挂在首页顶部的轮播推荐搬到这里，
 * 下面接「最新电影 / 最新电视剧」两条横滑导轨 + 「最近更新」竖排网格。
 *
 * 与首页的分工：首页负责「按分类逛」，推荐页负责「直接看点什么的」。
 */
@Component
export struct RecommendPage {
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  /** 源管理页改动配置后 bump 这个值，本页自动重载 */
  @StorageProp('configVersion') @Watch('onConfigVersion') cfgVersion: number = 0;
  /** 订阅主题版本：AppTheme 的 getter 不是响应式的，主题切换后靠它触发重渲染 */
  @StorageProp('themeVersion') themeVersion: number = 0;

  /** 轮播（取「最近更新」前几条） */
  @State banners: VodItem[] = [];
  @State railMovies: VodItem[] = [];
  @State railTvs: VodItem[] = [];
  @State railCardW: number = 104;
  @State railPosterH: number = 148;

  @State items: VodItem[] = [];
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State errMsg: string = '';
  @State sourceName: string = '';
  @State columns: number = 3;
  @State cardW: number = 110;
  @State posterH: number = 156;

  private bannerCtrl: SwiperController = new SwiperController();
  private rowDs: VodRowDataSource = new VodRowDataSource();
  private scroller: Scroller = new Scroller();
  private site: SiteModel | undefined = undefined;
  private page: number = 1;
  private pageCount: number = 1;
  private busy: boolean = false;
  private booted: boolean = false;
  private innerW: number = 0;
  /** 启动探测已拿到的「最近更新」第一页，复用省一次请求 */
  private probePage: VodPage | undefined = undefined;
  /** 请求代号：配置源切换后旧请求回来直接丢弃 */
  private reqSeq: number = 0;

  aboutToAppear(): void {
    this.bootstrap();
  }

  onConfigVersion(): void {
    this.reqSeq++;
    this.probePage = undefined;
    this.booted = false;
    SiteProbe.clear();
    this.bootstrap();
  }

  build() {
    Column() {
      /* ---------------- 顶部栏 ---------------- */
      Row() {
        Column() {
          Text('推荐')
            .fontSize(20)
            .fontColor(AppTheme.TEXT_PRIMARY)
            .fontWeight(FontWeight.Bold)
          Text(this.headerSub())
            .fontSize(11)
            .fontColor(AppTheme.TEXT_TERTIARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('搜索')
          .fontSize(13)
          .fontColor(AppTheme.TEXT_SECONDARY)
          .backgroundColor(AppTheme.CARD)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .onClick(() => {
            this.goSearch();
          })
      }
      .width('100%')
      .padding({ left: PAD, right: PAD, top: 8, bottom: 6 })

      List({ scroller: this.scroller }) {
        /* ---------------- 轮播推荐 ---------------- */
        if (this.banners.length > 0) {
          ListItem() {
            Swiper(this.bannerCtrl) {
              ForEach(this.banners, (v: VodItem) => {
                Stack({ alignContent: Alignment.BottomStart }) {
                  Image(v.pic)
                    .alt($r('app.media.background'))
                    .width('100%')
                    .height('100%')
                    .objectFit(ImageFit.Cover)
                    .backgroundColor(AppTheme.PLACEHOLDER)
                    .draggable(false)

                  Column({ space: 3 }) {
                    Text(v.name)
                      .fontSize(15)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#FFFFFF')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text(RecommendPage.bannerSub(v))
                      .fontSize(11)
                      .fontColor('#D6DAE3')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .padding({ left: 12, right: 12, top: 26, bottom: 10 })
                  .linearGradient({
                    direction: GradientDirection.Bottom,
                    colors: [['rgba(0,0,0,0.0)', 0.0], ['rgba(0,0,0,0.72)', 1.0]]
                  })
                }
                .width('100%')
                .height('100%')
                .onClick(() => {
                  this.openDetail(v);
                })
              }, (v: VodItem) => `bn_${v.siteKey}_${v.id}`)
            }
            .autoPlay(true)
            .interval(4000)
            .loop(true)
            .duration(420)
            .indicator(true)
            .width('100%')
            .height(BANNER_H)
            .borderRadius(AppTheme.RADIUS_CARD)
            .clip(true)
            .padding({ left: PAD, right: PAD })
          }
          .padding({ bottom: 16 })
        }

        /* ---------------- 最新电影 ---------------- */
        if (this.railMovies.length > 0) {
          ListItem() {
            VodRail({
              title: '最新电影',
              cardW: this.railCardW,
              posterH: this.railPosterH,
              gap: GAP,
              items: this.railMovies,
              onTap: (v: VodItem) => {
                this.openDetail(v);
              }
            })
          }
          .padding({ bottom: 16 })
        }

        /* ---------------- 最新电视剧 ---------------- */
        if (this.railTvs.length > 0) {
          ListItem() {
            VodRail({
              title: '最新电视剧',
              cardW: this.railCardW,
              posterH: this.railPosterH,
              gap: GAP,
              items: this.railTvs,
              onTap: (v: VodItem) => {
                this.openDetail(v);
              }
            })
          }
          .padding({ bottom: 16 })
        }

        /* ---------------- 最近更新 ---------------- */
        ListItem() {
          Row() {
            Text('最近更新')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.TEXT_PRIMARY)
              .layoutWeight(1)
            if (this.site !== undefined) {
              Text(this.site.name)
                .fontSize(10)
                .fontColor(AppTheme.TEXT_TERTIARY)
            }
          }
          .width('100%')
          .padding({ bottom: 8 })
        }

        if (this.loading && this.items.length === 0) {
          ForEach(this.skeletonIndexes(), (i: number) => {
            ListItem() {
              VodListSkeleton({ cardW: this.cardW, posterH: this.posterH, count: this.columns, gap: GAP })
            }
          }, (i: number) => `sk_${i}`)
        } else if (this.items.length === 0) {
          ListItem() {
            VodEmptyView({
              text: '暂无内容',
              hint: this.emptyHint(),
              actionText: '重新加载',
              onAction: () => {
                this.reload();
              }
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
                onTap: (v: VodItem) => {
                  this.openDetail(v);
                }
              })
            }
            .padding({ bottom: 12 })
          }, (row: VodRow) => row.key)

          if (this.loadingMore) {
            ListItem() {
              Row({ space: 8 }) {
                LoadingProgress()
                  .width(20)
                  .height(20)
                  .color(AppTheme.TEXT_SECONDARY)
                Text('加载中…')
                  .fontSize(12)
                  .fontColor(AppTheme.TEXT_TERTIARY)
              }
              .width('100%')
              .height(46)
              .justifyContent(FlexAlign.Center)
            }
          }

          if (this.page >= this.pageCount) {
            ListItem() {
              Text('— 已经到底了 —')
                .fontSize(11)
                .fontColor(AppTheme.TEXT_TERTIARY)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 10, bottom: 24 })
            }
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: PAD, right: PAD, top: 6 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onReachEnd(() => {
        this.loadMore();
      })
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

  /* ==================== 业务逻辑 ==================== */

  private async bootstrap(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.booted = true;
    this.loading = true;
    this.errMsg = '';
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await ConfigManager.get().ensureInit(ctx);
      const cfg = ConfigManager.get();
      this.sourceName = cfg.sourceDesc;
      const picked: ProbeResult = await SiteProbe.pick(cfg.sites);
      this.site = picked.site;
      this.probePage = picked.page;

      if (this.site === undefined) {
        this.loading = false;
        this.errMsg = '没有可用的资源站。ArkTS 无法加载 Spider(JAR)，请到「源管理」换一个以 type:1 采集站为主的配置源。';
        return;
      }

      // 「最近更新」第一页：优先复用探测结果，避免重复请求
      let first: VodPage | undefined = this.probePage;
      this.probePage = undefined;
      if (first === undefined) {
        first = await SiteRouter.latest(this.site, 1);
      }
      this.applyFirstPage(first);

      // 两条导轨（并发）
      await this.loadRails();
    } catch (e) {
      this.loading = false;
      this.errMsg = `初始化异常: ${e}`;
      Log.e(TAG, this.errMsg);
    } finally {
      this.busy = false;
      this.loading = false;
    }
  }

  private applyFirstPage(page: VodPage): void {
    this.loading = false;
    if (!page.ok || page.items.length === 0) {
      this.items = [];
      this.page = 1;
      this.pageCount = 1;
      this.rebuildRows();
      this.errMsg = page.error.length > 0 ? `「${page.error}」` : '这个源暂时没有内容';
      Log.w(TAG, `first page empty: ${page.error}`);
      return;
    }
    this.errMsg = '';
    this.page = 1;
    this.pageCount = page.pageCount > 0 ? page.pageCount : 1;
    this.items = page.items;
    this.syncBanners();
    this.rebuildRows();
    Log.i(TAG, `latest loaded count=${page.items.length} pages=${this.pageCount}`);
  }

  /** 轮播只取前几条有图的 */
  private syncBanners(): void {
    const out: VodItem[] = [];
    for (let i = 0; i < this.items.length && out.length < BANNER_COUNT; i++) {
      const v: VodItem = this.items[i];
      if (v.pic !== undefined && v.pic.length > 0) {
        out.push(v);
      }
    }
    // 内容没变不要整体赋值，否则 Swiper 会被重置回第一张
    if (RecommendPage.sameList(out, this.banners)) {
      return;
    }
    this.banners = out;
  }

  private static sameList(a: VodItem[], b: VodItem[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i].id !== b[i].id || a[i].siteKey !== b[i].siteKey) {
        return false;
      }
    }
    return true;
  }

  private static bannerSub(v: VodItem): string {
    const parts: string[] = [];
    if (v.remarks.length > 0) {
      parts.push(v.remarks);
    }
    if (v.typeName.length > 0) {
      parts.push(v.typeName);
    }
    if (v.year.length > 0) {
      parts.push(v.year);
    }
    if (parts.length === 0) {
      parts.push(v.siteName);
    }
    return parts.join(' · ');
  }

  /**
   * 加载「最新电影 / 最新电视剧」两条导轨。
   *
   * 站点分类里「电影 / 连续剧」这类容器分类经常查不到内容（影片都挂在子分类上），
   * 所以按站点自己的分类顺序列出候选 id，逐个试到第一个有内容的为止。
   */
  private async loadRails(): Promise<void> {
    if (this.site === undefined) {
      return;
    }
    let cls: ClassModel[] = await SiteProbe.classes(this.site);
    if (cls.length === 0) {
      // 站点不给分类时退回配置里的 classes
      cls = ConfigManager.get().classes;
    }
    if (cls.length === 0) {
      Log.w(TAG, 'no classes, rails skipped');
      return;
    }
    const movieIds: string[] = RecommendPage.candidates(cls, KIND_MOVIE);
    const tvIds: string[] = RecommendPage.candidates(cls, KIND_TV);

    const jobs: Promise<VodItem[]>[] = [
      this.fetchRail(movieIds),
      this.fetchRail(tvIds)
    ];
    let res: VodItem[][] = [];
    try {
      res = await Promise.all(jobs);
    } catch (e) {
      Log.w(TAG, `rails failed: ${e}`);
      return;
    }
    this.railMovies = res[0];
    this.railTvs = res[1];
    Log.i(TAG, `rails: movie=${this.railMovies.length} tv=${this.railTvs.length}`);
  }

  /** 顺着候选 id 找到第一个有内容的分类，取它的第一页 */
  private async fetchRail(ids: string[]): Promise<VodItem[]> {
    if (this.site === undefined) {
      return [];
    }
    const site: SiteModel = this.site;
    for (let i = 0; i < ids.length; i++) {
      let page: VodPage = new VodPage();
      try {
        page = await SiteRouter.category(site, ids[i], 1, []);
      } catch (e) {
        Log.w(TAG, `rail ${ids[i]} failed: ${e}`);
        continue;
      }
      if (page.ok && page.items.length > 0) {
        const out: VodItem[] = [];
        for (let j = 0; j < page.items.length && out.length < RAIL_LIMIT; j++) {
          out.push(page.items[j]);
        }
        Log.i(TAG, `rail id=${ids[i]} count=${out.length}`);
        return out;
      }
      Log.w(TAG, `rail id=${ids[i]} empty: ${page.error}`);
    }
    return [];
  }

  /** 按站点原始顺序挑出属于该分组的分类 id（容器在前，子分类在后） */
  private static candidates(cls: ClassModel[], kind: number): string[] {
    const out: string[] = [];
    for (let i = 0; i < cls.length && out.length < RAIL_CANDIDATES; i++) {
      const c: ClassModel = cls[i];
      if (c === undefined || c.type_name === undefined || c.type_name.length === 0) {
        continue;
      }
      if (RecommendPage.belongsTo(c.type_name, kind)) {
        const id: string = `${c.type_id}`;
        if (out.indexOf(id) < 0) {
          out.push(id);
        }
      }
    }
    return out;
  }

  private static belongsTo(name: string, kind: number): boolean {
    const isVariety: boolean = name.indexOf('综艺') >= 0 || name.indexOf('动漫') >= 0
      || name.indexOf('动画') >= 0 || name.indexOf('预告') >= 0;
    if (kind === KIND_MOVIE) {
      if (isVariety) {
        return false;
      }
      // 「电影」「动作片」「喜剧片」都算电影；「片」结尾是采集站最常见的电影子分类命名
      return name.indexOf('电影') >= 0 || name.endsWith('片');
    }
    if (isVariety || name.indexOf('电影') >= 0 || name.indexOf('片') >= 0) {
      return false;
    }
    return name.indexOf('剧') >= 0;
  }

  /* ---------------- 「最近更新」翻页 ---------------- */

  private async loadMore(): Promise<void> {
    if (this.busy || this.loading || this.loadingMore) {
      return;
    }
    if (this.site === undefined || this.page >= this.pageCount) {
      return;
    }
    this.loadingMore = true;
    const seq: number = this.reqSeq;
    const target: number = this.page + 1;
    let page: VodPage = new VodPage();
    try {
      page = await SiteRouter.latest(this.site, target);
    } catch (e) {
      this.loadingMore = false;
      Log.w(TAG, `loadMore failed: ${e}`);
      return;
    }
    if (seq !== this.reqSeq) {
      return;
    }
    this.loadingMore = false;
    if (!page.ok || page.items.length === 0) {
      // 到底了：把游标推到当前页，避免触底反复请求
      this.pageCount = this.page;
      return;
    }
    this.page = target;
    this.pageCount = page.pageCount > 0 ? page.pageCount : this.pageCount;
    this.items = this.items.concat(page.items);
    this.rebuildRows();
    Log.i(TAG, `loadMore page=${this.page}/${this.pageCount} count=${page.items.length}`);
  }

  private reload(): void {
    this.reqSeq++;
    this.items = [];
    this.rebuildRows();
    this.loading = true;
    this.errMsg = '';
    this.booted = false;
    this.bootstrap();
  }

  private rebuildRows(): void {
    const rows: VodRow[] = VodRow.chunk(this.items, this.columns, 'rec');
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
    const cols: number = RecommendPage.columnsFor(inner);
    const cardW: number = Math.floor((inner - GAP * (cols - 1)) / cols);
    this.columns = cols;
    this.cardW = cardW;
    this.posterH = Math.floor(cardW * 1.42);
    // 导轨卡片稍窄，让右侧能露出下一张的一角，提示可横滑
    const rail: number = Math.floor(inner * 0.28);
    this.railCardW = rail < 96 ? 96 : (rail > 132 ? 132 : rail);
    this.railPosterH = Math.floor(this.railCardW * 1.42);
    this.rebuildRows();
  }

  private headerSub(): string {
    const parts: string[] = [];
    if (this.site !== undefined) {
      parts.push(this.site.name);
    } else if (this.sourceName.length > 0) {
      parts.push(this.sourceName);
    }
    parts.push('为你推荐');
    return parts.join(' · ');
  }

  private emptyHint(): string {
    if (this.errMsg.length > 0) {
      return this.errMsg;
    }
    return '换个配置源，或到「首页」按分类浏览';
  }

  private skeletonIndexes(): number[] {
    const out: number[] = [];
    for (let i = 0; i < 3; i++) {
      out.push(i);
    }
    return out;
  }

  private openDetail(v: VodItem): void {
    const p: DetailParams = new DetailParams();
    p.vod = v;
    this.getUIContext().getRouter().pushUrl({ url: 'features/detail/view/VideoDetailPage', params: p }).catch(() => {
      ToastUtil.show(this.getUIContext(), '无法打开详情页');
    });
  }

  private goSearch(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'features/search/view/SearchPage' }).catch(() => {
      ToastUtil.show(this.getUIContext(), '无法打开搜索页');
    });
  }

  /** 断点 → 列数（与首页保持一致） */
  private static columnsFor(innerW: number): number {
    if (innerW < 320) {
      return 2;
    }
    if (innerW < 600) {
      return 3;
    }
    if (innerW < 840) {
      return 4;
    }
    if (innerW < 1080) {
      return 5;
    }
    return 6;
  }
}
