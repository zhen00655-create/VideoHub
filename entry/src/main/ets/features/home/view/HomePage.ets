import { common } from '@kit.AbilityKit';
import {
  CategoryModel, ClassModel, FilterItemModel, FilterValueModel, SiteModel, VodItem
} from '../../../commons/models/TvBoxModels';
import { DetailParams } from '../../../commons/models/RouteParams';
import { ConfigManager } from '../../source/ConfigLoader';
import { FilterSel, SiteRouter, VodPage } from '../../source/SiteRouter';
import { ProbeResult, SiteProbe } from '../../source/SiteProbe';
import { AppTheme } from '../../../commons/theme/AppTheme';
import { HomeContentPane, TabEntry, PaneState } from '../component/HomeContentPane';
import { Log } from '../../../commons/utils/LogUtil';
import { ToastUtil } from '../../../commons/utils/ToastUtil';

const TAG = 'HomePage';
const PAD: number = AppTheme.PAGE_PADDING;
const GAP: number = 9;

/**
 * 「最近更新」伪分类。
 *
 * MacCMS 的 `?ac=videolist&t=<父分类>` 在多数站点返回 0 条（父分类只是个容器），
 * 首页第一个页签固定指向它，保证首屏一定有内容。
 */
const LATEST_ID: string = '__latest__';

/**
 * 苹果CMS 的「容器分类」名。
 *
 * 这类分类在多数采集站上只是个分组壳子：`?ac=videolist&t=1`（电影）实测 total=0，
 * 因为它们本身不挂影片，影片都挂在子分类（动作片/喜剧片…）上。
 * 首页把同名的容器当成分组页签，选中的其实是它下面的第一个子分类。
 */
const UMBRELLA_NAMES: string[] = [
  '电影', '电影片', '电视剧', '电视剧片', '连续剧', '综艺', '综艺片', '动漫', '动漫片', '动画',
  '体育', '短剧', '少儿'
];

/** 页签 / 胶囊选中态配色过渡时长 */
const TAB_TINT_MS: number = 200;
/** 筛选面板展开、收起的时长 */
const FILTER_MS: number = 220;
/**
 * Swiper 切换分类的时长。
 * 用 FastOutSlowIn（快出慢入）而不是 Linear：翻页应当是「快速起步 → 减速停住」，
 * 线性速度看起来像机械平移，就是"生硬"的来源。
 */
const SWIPE_DURATION_MS: number = 320;

/**
 * ⚠️ `TabEntry`（内容槽）与 `PaneState`（可观测状态槽）都定义在 `HomeContentPane.ets`，
 *    这里只 import：那边需要导出 `PaneState` 给 @ObjectLink 用，若把 TabEntry 留在这边，
 *    两个文件就会互相 import 成环。
 */

/**
 * `entries` 与 `categories` 不是同一帧落地的（分类先到、槽随后建），
 * 中间那一帧取值要有兜底对象，否则会被判越界。
 */
const FALLBACK_ENTRY: TabEntry = new TabEntry();

@Component
export struct HomePage {
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  /** 源管理页改动配置后 bump 这个值，首页自动重载 */
  @StorageProp('configVersion') @Watch('onConfigVersion') cfgVersion: number = 0;
  /**
   * 可用源数量。
   *
   * ⚠️ 不能写成「build 时现读 `ConfigManager.get().sites.length`」：`sites` 不是被观测的对象，
   *    冷启动首帧配置还没 rebuild，读到的是空数组 → 顶部显示「0 个可用源」，
   *    而之后 sites 变成 8 时没有任何信号把它推回界面，就一直停在 0（源管理页却正常，
   *    因为它有 onPageShow 主动同步）。改由 ConfigManager 在站点变化时发布到 AppStorage，
   *    这里订阅，才是真正响应式的。
   */
  @StorageProp('usableSiteCount') usableSiteCount: number = 0;
  /** 订阅主题版本：AppTheme 的 getter 不是响应式的，主题切换后靠它触发重渲染 */
  @StorageProp('themeVersion') themeVersion: number = 0;

  @State categories: CategoryModel[] = [];
  @State activeTab: number = 0;
  /** 当前一级分类下的二级分类（MacCMS 的 type_pid 层级） */
  @State subCategories: CategoryModel[] = [];
  @State activeSub: number = 0;
  @State filterDims: FilterItemModel[] = [];
  @State selections: FilterSel[] = [];
  @State showFilters: boolean = false;
  /**
   * 每个一级分类一个内容槽。
   *
   * ⚠️⚠️ 刻意用**普通成员**（不加 @State），也不再靠「自增版本号逼父组件重渲染」那套：
   *      槽里装着 `Scroller` 与 `IDataSource`，都是框架对象，不该被状态装饰器包装；
   *      而状态下发改由子组件的 `@ObjectLink pane` 直接订阅（见 `PaneState` 注释）——
   *      Swiper 会跳过离屏页的父→子 @Prop 推送，那正是「数据到了界面却不画」的原因。
   *      分类数组本身仍是 @State（`categories`），它一变就会整批重建内容页。
   */
  private entries: TabEntry[] = [];

  private site: SiteModel | undefined = undefined;
  private innerW: number = 0;
  private booted: boolean = false;
  /**
   * 全局请求代号。每个槽另外记自己的 `seq`，响应回来只认自己那一份 ——
   * 这样「预取相邻分类」的在途请求不会把当前分类的数据冲掉。
   */
  private reqSeq: number = 0;
  private sourceName: string = '';
  /** 一级分类页签的滚动控制器：切换时把选中页签平滑滚到可视区中间 */
  private tabScroller: Scroller = new Scroller();
  /** 二级分类页签的滚动控制器 */
  private subScroller: Scroller = new Scroller();
  /** 站点探测时已经拿到的「最近更新」首页数据，直接复用不重复请求 */
  private probePage: VodPage | undefined = undefined;

  aboutToAppear(): void {
    this.bootstrap();
  }

  onConfigVersion(): void {
    this.entries = [];
    this.reqSeq++;
    this.probePage = undefined;
    this.booted = false;
    // 站点探测与分类缓存都与配置源绑定，配置换了必须整体作废
    SiteProbe.clear();
    this.bootstrap();
  }

  build() {
    Column() {
      /* ---------------- 顶部栏 ---------------- */
      Row() {
        Column() {
          Text('影视观')
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
          .margin({ right: 8 })
          .onClick(() => {
            this.goSearch();
          })

        if (this.filterDims.length > 0) {
          Text(this.showFilters ? '收起' : '筛选')
            .fontSize(12)
            .fontColor(this.showFilters ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
            .backgroundColor(this.showFilters ? AppTheme.ACCENT : AppTheme.CARD)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(AppTheme.RADIUS_PILL)
            .margin({ right: 8 })
            .animation({ duration: TAB_TINT_MS, curve: Curve.EaseOut })
            .onClick(() => {
              this.toggleFilters();
            })
        }

        Text('源管理')
          .fontSize(12)
          .fontColor(AppTheme.TEXT_SECONDARY)
          .backgroundColor(AppTheme.CARD)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .onClick(() => {
            this.goSource();
          })

        Text('设置')
          .fontSize(13)
          .fontColor(AppTheme.TEXT_SECONDARY)
          .backgroundColor(AppTheme.CARD)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .margin({ right: 8 })
          .onClick(() => {
            this.goSetting();
          })

      }
      .width('100%')
      .padding({ left: PAD, right: PAD, top: 8, bottom: 6 })

      /* ---------------- 分类页签 ---------------- */
      if (this.categories.length > 0) {
        /*
         * 用横向 List 而不是 Scroll + Row：List 支持 scrollToIndex(idx, true, CENTER)，
         * 切换分类时能把选中页签平滑滚到可视区正中 —— 分类多起来以后，
         * 点击/滑动切到靠后的分类，页签自己会跟过来，不会"选中项跑到屏幕外看不见"。
         */
        List({ scroller: this.tabScroller, space: 8 }) {
          ForEach(this.categories, (c: CategoryModel, idx: number) => {
            ListItem() {
              Text(c.name)
                .fontSize(14)
                .fontWeight(this.activeTab === idx ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.activeTab === idx ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
                .padding({ left: 4, right: 4, top: 6, bottom: 6 })
                .border({
                  width: { bottom: 2 },
                  color: this.activeTab === idx ? AppTheme.ACCENT : '#00000000'
                })
                .animation({ duration: TAB_TINT_MS, curve: Curve.EaseOut })
                .onClick(() => {
                  this.switchTab(idx);
                })
            }
          }, (c: CategoryModel, idx: number) => `cat_${idx}_${c.name}`)
        }
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .height(36)
        .padding({ left: PAD, right: PAD })
      }

      /* ---------------- 二级分类（父分类下的具体类型） ---------------- */
      if (this.subCategories.length > 0) {
        List({ scroller: this.subScroller, space: 8 }) {
          ForEach(this.subCategories, (c: CategoryModel, idx: number) => {
            ListItem() {
              Text(c.name)
                .fontSize(12)
                .fontColor(this.activeSub === idx ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
                .backgroundColor(this.activeSub === idx ? AppTheme.ACCENT : AppTheme.CARD)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(AppTheme.RADIUS_PILL)
                .animation({ duration: TAB_TINT_MS, curve: Curve.EaseOut })
                .onClick(() => {
                  this.switchSub(idx);
                })
            }
          }, (c: CategoryModel, idx: number) => `sub_${idx}_${c.id}`)
        }
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .height(38)
        .padding({ left: PAD, right: PAD })
      }

      /* ---------------- 筛选面板 ---------------- */
      if (this.showFilters && this.filterDims.length > 0) {
        Column() {
          ForEach(this.filterDims, (dim: FilterItemModel) => {
            Row() {
              Text(dim.name)
                .fontSize(12)
                .fontColor(AppTheme.TEXT_TERTIARY)
                .width(46)
              Scroll() {
                Row({ space: 8 }) {
                  ForEach(dim.value, (fv: FilterValueModel) => {
                    Text(fv.n)
                      .fontSize(12)
                      .fontColor(this.selectedValueOf(dim.key) === fv.v ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
                      .backgroundColor(this.selectedValueOf(dim.key) === fv.v ? AppTheme.ACCENT : AppTheme.CARD)
                      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                      .borderRadius(AppTheme.RADIUS_PILL)
                      .animation({ duration: TAB_TINT_MS, curve: Curve.EaseOut })
                      .onClick(() => {
                        this.selectFilter(dim.key, fv.v);
                      })
                  }, (fv: FilterValueModel) => `fv_${dim.key}_${fv.v}`)
                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .align(Alignment.TopStart)
              .layoutWeight(1)
            }
            .width('100%')
            .height(40)
          }, (dim: FilterItemModel) => `dim_${dim.key}`)
        }
        .width('100%')
        .padding({ left: PAD, right: PAD })
        .transition(
          TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: -12 }))
            .animation({ duration: FILTER_MS, curve: Curve.EaseOut })
        )
      }

      /* ---------------- 内容区：一个分类一页，左右滑动跟手翻页 ---------------- */
      Swiper() {
        ForEach(this.categories, (c: CategoryModel, idx: number) => {
          HomeContentPane({
            /**
             * ⚠️ pane 走 @ObjectLink、ds/scroller 走无装饰器成员：
             *    页面自己订阅状态槽，不再依赖父组件把一屏 @Prop 推下来 ——
             *    Swiper 会跳过离屏页的父→子推送，那正是「请求成功、数据也写进
             *    数据源了，界面却一直停在骨架上」的原因。
             */
            pane: this.entryOf(idx).pane,
            emptyActionText: idx === 0 ? '重新加载' : '看最近更新',
            ds: this.entryOf(idx).ds,
            scroller: this.entryOf(idx).scroller,
            onTapItem: (v: VodItem) => {
              this.openDetail(v);
            },
            onEmptyAction: () => {
              this.emptyAction(idx);
            },
            onReachEnd: () => {
              this.loadMoreFor(idx);
            },
            onArea: (a: Area) => {
              this.onArea(a);
            }
          })
        }, (c: CategoryModel, idx: number) => `pane_${idx}_${c.id}_${c.name}`)
      }
      .layoutWeight(1)
      .index(this.activeTab)
      .loop(false)
      .indicator(false)
      .duration(SWIPE_DURATION_MS)
      .curve(Curve.FastOutSlowIn)
      .cachedCount(1)
      .onChange((index: number) => {
        this.onSwiperChange(index);
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

  /* ==================== 数据槽 ==================== */

  private entryOf(index: number): TabEntry {
    if (index >= 0 && index < this.entries.length) {
      return this.entries[index];
    }
    return FALLBACK_ENTRY;
  }

  /** 分类和内容槽必须一起落地，否则中间会有一帧「有分类但没有槽」 */
  private applyCategories(cats: CategoryModel[]): void {
    const arr: TabEntry[] = [];
    for (let i = 0; i < cats.length; i++) {
      arr.push(new TabEntry());
    }
    this.entries = arr;
    this.categories = cats;
  }

  /* ==================== 业务逻辑 ==================== */

  private async bootstrap(): Promise<void> {
    if (this.booted) {
      return;
    }
    this.booted = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await ConfigManager.get().ensureInit(ctx);
      const cfg = ConfigManager.get();
      this.sourceName = cfg.sourceDesc;
      Log.i(TAG, `bootstrap: desc=${cfg.sourceDesc} sites=${cfg.sites.length} usableSiteCount=${this.usableSiteCount}`);
      const picked: ProbeResult = await SiteProbe.pick(cfg.sites);
      this.site = picked.site;
      this.probePage = picked.page;
      await this.loadCategories();
      await this.loadFor(0, true, true);
    } catch (e) {
      if (this.entries.length === 0) {
        this.entries = [new TabEntry()];
      }
      const e0: TabEntry = this.entries[0];
      e0.pane.loaded = true;
      e0.pane.errMsg = `初始化异常: ${e}`;
      Log.e(TAG, `bootstrap failed: ${e}`);
    }
  }

  /**
   * 组装首页分类。
   *
   * 优先级：站点自身 `?ac=list` 的分类 > 配置里的 classes > 苹果CMS 默认分类。
   *
   * 必须站点优先：资源站是运行时探测出来的（见 `SiteProbe.pick`），而配置里的 classes 中的
   * type_id 是按配置作者那台站的分类表写的，换到别的站必然对不上，点进去就是空白。
   */
  private async loadCategories(): Promise<void> {
    const cfg = ConfigManager.get();
    const flat: CategoryModel[] = [];

    if (this.site !== undefined) {
      try {
        // 走 SiteProbe.classes：带缓存，推荐页也要这份分类，避免两边各请求一次
        const fromSite: ClassModel[] = await SiteProbe.classes(this.site);
        for (let i = 0; i < fromSite.length; i++) {
          const c: ClassModel = fromSite[i];
          if (c === undefined || c.type_name === undefined || c.type_name.length === 0) {
            continue;
          }
          const pid: string = (c.type_pid === undefined || c.type_pid === null) ? '' : `${c.type_pid}`;
          flat.push(HomePage.toCategory(`${c.type_id}`, c.type_name, pid, []));
        }
        Log.i(TAG, `classes from site ${this.site.name}: ${flat.length}`);
      } catch (e) {
        Log.w(TAG, `classes from site failed: ${e}`);
      }
    }

    // 站点不给分类时退回配置里的 classes
    if (flat.length === 0) {
      const cls: ClassModel[] = cfg.classes;
      if (cls !== undefined && cls.length > 0) {
        for (let i = 0; i < cls.length; i++) {
          const c: ClassModel = cls[i];
          if (c === undefined || c.type_name === undefined) {
            continue;
          }
          const filters: FilterItemModel[] =
            (c.filters !== undefined && c.filters.by !== undefined) ? c.filters.by : [];
          flat.push(HomePage.toCategory(`${c.type_id}`, c.type_name, '', filters));
        }
      }
    }

    // 最后兜底：苹果CMS 默认分类 id
    if (flat.length === 0) {
      flat.push(HomePage.toCategory('1', '电影', '', []));
      flat.push(HomePage.toCategory('2', '连续剧', '', []));
      flat.push(HomePage.toCategory('3', '综艺', '', []));
      flat.push(HomePage.toCategory('4', '动漫', '', []));
    }

    const tree: CategoryModel[] = HomePage.buildTree(flat);
    this.applyCategories(tree);
    this.activeTab = 0;
    this.applyTab(0);
    const desc: string[] = [];
    for (let i = 0; i < tree.length; i++) {
      const c: CategoryModel = tree[i];
      desc.push(c.children.length > 0 ? `${c.name}[${c.children.length}]` : c.name);
    }
    Log.i(TAG, `tabs: ${desc.join(' / ')}`);
  }

  /** 组装页签树：第 0 个固定是「最近更新」，其余按层级归组 */
  private static buildTree(flat: CategoryModel[]): CategoryModel[] {
    const out: CategoryModel[] = [];
    out.push(HomePage.toCategory(LATEST_ID, '最近更新', '', []));
    if (flat.length === 0) {
      return out;
    }

    let hasTree: boolean = false;
    for (let i = 0; i < flat.length; i++) {
      const p: string = flat[i].pid;
      if (p.length > 0 && p !== '0') {
        hasTree = true;
        break;
      }
    }
    if (hasTree) {
      HomePage.attachByPid(flat, out);
    } else {
      HomePage.attachByName(flat, out);
    }
    return out;
  }

  /** 有 type_pid 时按 id 建真实层级 */
  private static attachByPid(flat: CategoryModel[], out: CategoryModel[]): void {
    const byId: Map<string, CategoryModel> = new Map<string, CategoryModel>();
    for (let i = 0; i < flat.length; i++) {
      byId.set(flat[i].id, flat[i]);
    }
    for (let i = 0; i < flat.length; i++) {
      const c: CategoryModel = flat[i];
      const pid: string = c.pid;
      let attached: boolean = false;
      if (pid.length > 0 && pid !== '0') {
        const parent: CategoryModel | undefined = byId.get(pid);
        if (parent !== undefined && parent !== c) {
          parent.children.push(c);
          attached = true;
        }
      }
      if (!attached) {
        out.push(c);
      }
    }
  }

  /**
   * 站点不返回 type_pid 时按名称归组。
   *
   * 实测数据：百度 / 索尼这类采集站给的是一串扁平分类
   *   1:电影 2:电视剧 3:综艺 4:动漫 6:动作片 7:喜剧片 … 62:4K电影 …
   * 其中 1~4 是纯容器（`t=1` 实测 total=0），影片全挂在子分类上。
   * 按名称把叶子挂到同名容器下之后，「电影」页签默认落到「动作片」，
   * 而不是去请求必然为空的 `t=1`。
   */
  private static attachByName(flat: CategoryModel[], out: CategoryModel[]): void {
    const groups: Map<string, CategoryModel> = new Map<string, CategoryModel>();
    for (let i = 0; i < flat.length; i++) {
      if (HomePage.isUmbrella(flat[i].name)) {
        groups.set(flat[i].name, flat[i]);
      }
    }

    const assigned: Set<CategoryModel> = new Set<CategoryModel>();
    const extra: CategoryModel[] = [];
    for (let i = 0; i < flat.length; i++) {
      const c: CategoryModel = flat[i];
      if (HomePage.isUmbrella(c.name)) {
        continue;
      }
      const g: string = HomePage.inferGroup(c.name);
      if (g.length === 0) {
        continue;
      }
      let holder: CategoryModel | undefined = groups.get(g);
      if (holder === undefined) {
        // 站点只有「体育赛事/篮球/足球」而没有「体育」这类容器时，造一个纯分组的
        // 虚拟容器（id 为空）。它自己永远不会被请求，只负责把子分类收拢起来。
        if (!HomePage.isUmbrella(g)) {
          continue;
        }
        holder = HomePage.toCategory('', g, '', []);
        groups.set(g, holder);
        extra.push(holder);
      }
      holder.children.push(c);
      assigned.add(c);
    }

    // 按站点返回的原始顺序输出，保证页签排列稳定
    for (let i = 0; i < flat.length; i++) {
      const c: CategoryModel = flat[i];
      if (assigned.has(c)) {
        continue;
      }
      out.push(c);
    }
    for (let i = 0; i < extra.length; i++) {
      out.push(extra[i]);
    }
  }

  private static isUmbrella(name: string): boolean {
    for (let i = 0; i < UMBRELLA_NAMES.length; i++) {
      if (UMBRELLA_NAMES[i] === name) {
        return true;
      }
    }
    return false;
  }

  /** 按名称判断一个分类属于哪个容器分组；返回 '' 表示不归组，自己当顶层页签 */
  private static inferGroup(name: string): string {
    const n: string = name;
    if (n.indexOf('短剧') >= 0 || n.indexOf('爽剧') >= 0) {
      return '短剧';
    }
    if (n.indexOf('动画') >= 0 || n.indexOf('动漫') >= 0 || n === '漫剧') {
      return '动漫';
    }
    if (n.indexOf('综艺') >= 0) {
      return '综艺';
    }
    if (n.indexOf('纪录') >= 0) {
      return '纪录片';
    }
    if (n.indexOf('电影') >= 0) {
      return '电影';
    }
    if (n.endsWith('片') && n.indexOf('预告') < 0) {
      return '电影';
    }
    if (n.endsWith('剧')) {
      return '电视剧';
    }
    if (n.indexOf('体育') >= 0 || n === '篮球' || n === '足球' || n === '斯诺克') {
      return '体育';
    }
    if (n.indexOf('少儿') >= 0 || n.indexOf('儿童') >= 0 || n.indexOf('儿歌') >= 0) {
      return '少儿';
    }
    return '';
  }

  private static toCategory(id: string, name: string, pid: string, filters: FilterItemModel[]): CategoryModel {
    const m: CategoryModel = new CategoryModel();
    m.id = id;
    m.name = name;
    m.pid = pid;
    m.filters = filters;
    return m;
  }

  /** 切换一级页签时同步二级页签与筛选行（二级选择从该分类自己的槽里读回来） */
  private applyTab(index: number): void {
    if (index >= 0 && index < this.categories.length) {
      const c: CategoryModel = this.categories[index];
      this.subCategories = c.children;
      this.filterDims = c.filters;
      const e: TabEntry = this.entryOf(index);
      this.activeSub = e.sub;
      this.selections = e.filters;
    } else {
      this.subCategories = [];
      this.filterDims = [];
      this.activeSub = 0;
      this.selections = [];
    }
    this.showFilters = false;
  }

  /** 该分类真正要请求的 type_id */
  private requestIdOf(index: number): string {
    if (index < 0 || index >= this.categories.length) {
      return '';
    }
    const c: CategoryModel = this.categories[index];
    if (c.id === LATEST_ID) {
      return LATEST_ID;
    }
    const e: TabEntry = this.entryOf(index);
    if (e.sub >= 0 && e.sub < c.children.length) {
      return c.children[e.sub].id;
    }
    return c.id;
  }

  /** 该分类当前展示名（用于日志与空状态文案） */
  private categoryNameOf(index: number): string {
    if (index < 0 || index >= this.categories.length) {
      return '';
    }
    const c: CategoryModel = this.categories[index];
    const e: TabEntry = this.entryOf(index);
    if (e.sub >= 0 && e.sub < c.children.length) {
      return c.children[e.sub].name;
    }
    return c.name;
  }

  /** 该分类当前数据对应的缓存 key */
  private keyOf(index: number): string {
    const e: TabEntry = this.entryOf(index);
    let s: string = `tab${index}.${e.sub}`;
    for (let i = 0; i < e.filters.length; i++) {
      s += `|${e.filters[i].key}=${e.filters[i].value}`;
    }
    return s;
  }

  /**
   * 加载指定分类的内容。
   *
   * @param reset   true = 重新拉第一页（换分类/换筛选/重试），false = 上拉翻下一页
   * @param revive  完成时是否播放「内容进场」动效。预取（用户还没滑过去）时传 false，
   *                否则相邻页会在后台默默播一遍动画，等真滑过去时什么都看不见。
   */
  private async loadFor(index: number, reset: boolean, revive: boolean): Promise<void> {
    const e: TabEntry = this.entryOf(index);
    const name: string = this.categoryNameOf(index);
    const key: string = this.keyOf(index);
    const id: string = this.requestIdOf(index);

    if (this.site === undefined) {
      e.pane.loading = false;
      e.pane.loadingMore = false;
      e.pane.loaded = true;
      e.pane.errMsg = '没有可用的资源站。ArkTS 无法加载 Spider(JAR)，请到「源管理」换一个以 type:1 采集站为主的配置源。';
      return;
    }
    // 翻页必须串行：上一次还没回来就不要再发，否则同一页会被塞两遍
    if (!reset && (e.pane.loading || e.pane.loadingMore || e.pane.page >= e.pane.pageCount)) {
      return;
    }

    if (id.length === 0) {
      // 分组页签没有可请求的 type_id（虚拟容器 / 空分类列表），不要发无意义的请求
      e.pane.loading = false;
      e.pane.loadingMore = false;
      e.pane.loaded = true;
      e.pane.errMsg = '这个分类没有可用的子分类，换一个页签试试。';
      return;
    }

    // 启动探测时已经拿到「最近更新」第一页，直接复用，省一次请求也避免二次闪烁
    if (reset && id === LATEST_ID && this.probePage !== undefined) {
      const seed: VodPage = this.probePage;
      this.probePage = undefined;
      e.pane.loading = false;
      e.pane.loadingMore = false;
      e.pane.loaded = true;
      e.pane.page = 1;
      e.pane.pageCount = seed.pageCount > 0 ? seed.pageCount : 1;
      e.items = seed.items;
      e.pane.errMsg = '';
      e.key = key;
      e.setRows(index);
      if (revive) {
        e.pane.reviveTick++;
      }
      Log.i(TAG, `latest seeded from probe count=${seed.items.length} pages=${e.pane.pageCount}`);
      this.prefetch(index);
      return;
    }

    // 请求前先记下代号：回来时代号变了说明期间又切了分类/筛选，结果整体丢弃
    const seq: number = ++this.reqSeq;
    e.seq = seq;
    const targetPage: number = reset ? 1 : e.pane.page + 1;
    const filters: FilterSel[] = e.filters.slice();

    if (reset) {
      e.pane.page = 1;
      e.pane.pageCount = 1;
      e.items = [];
      e.clearRows();
      e.pane.errMsg = '';
      e.pane.loading = true;
      e.pane.loaded = false;
    } else {
      e.pane.loadingMore = true;
    }
    e.key = key;

    let page: VodPage = new VodPage();
    try {
      if (id === LATEST_ID) {
        page = await SiteRouter.latest(this.site, targetPage);
      } else {
        page = await SiteRouter.category(this.site, id, targetPage, filters);
      }
    } catch (err) {
      if (e.seq === seq) {
        e.pane.loading = false;
        e.pane.loadingMore = false;
        e.pane.loaded = true;
        e.pane.errMsg = `请求异常: ${err}`;
      }
      return;
    }

    // 期间用户又换了子分类/筛选：这次响应已经不属于当前视图，丢弃
    if (e.seq !== seq || key !== this.keyOf(index)) {
      Log.i(TAG, `drop stale resp key=${key} page=${targetPage} count=${page.items.length}`);
      return;
    }

    e.pane.loading = false;
    e.pane.loadingMore = false;
    e.pane.loaded = true;

    if (page.items.length === 0) {
      if (reset) {
        e.items = [];
        e.clearRows();
      }
      e.pane.errMsg = this.emptyMsg(index, name, page.error);
      // 把游标推到这一页，避免到底后反复请求同一个空页
      e.pane.page = targetPage;
      e.pane.pageCount = targetPage;
      if (revive) {
        e.pane.reviveTick++;
      }
      Log.w(TAG, `empty tab=${name} id=${id} key=${key} site=${this.site.key}`);
      if (index === this.activeTab) {
        this.prefetch(index);
      }
      return;
    }

    e.pane.errMsg = '';
    e.pane.page = targetPage;
    e.pane.pageCount = page.pageCount > 0 ? page.pageCount : 1;
    e.items = reset ? page.items : e.items.concat(page.items);
    e.setRows(index);
    if (revive) {
      e.pane.reviveTick++;
    }
    Log.i(TAG, `loaded tab=${name} id=${id} key=${key} page=${e.pane.page}/${e.pane.pageCount} count=${page.items.length}`);

    if (index === this.activeTab) {
      this.prefetch(index);
    }
  }

  /**
   * 预取左右相邻分类的第一页。
   *
   * 这是「划过去像翻页」的关键：等手指真的滑过去时，相邻分类已经有内容，
   * 滑过去看到的就是完整列表，而不是一片骨架。
   * 预取失败的响应只写进它自己的槽，不会影响当前分类。
   */
  private prefetch(center: number): void {
    this.prefetchOne(center - 1);
    this.prefetchOne(center + 1);
  }

  private prefetchOne(index: number): void {
    if (index < 0 || index >= this.entries.length) {
      return;
    }
    const e: TabEntry = this.entries[index];
    if (e.pane.loaded || e.pane.loading) {
      return;
    }
    this.loadFor(index, true, false);
  }

  private loadMoreFor(index: number): void {
    if (index !== this.activeTab) {
      return;
    }
    const e: TabEntry = this.entryOf(index);
    if (e.pane.loading || e.pane.loadingMore || e.pane.page >= e.pane.pageCount) {
      return;
    }
    this.loadFor(index, false, false);
  }

  private emptyMsg(index: number, name: string, error: string): string {
    const siteName: string = this.site !== undefined ? this.site.name : '当前源';
    if (error.length > 0) {
      return `「${siteName}」请求失败：${error}`;
    }
    const hasSub: boolean = index >= 0 && index < this.categories.length
      && this.categories[index].children.length > 0;
    if (hasSub) {
      return `「${siteName}」的「${name}」暂无内容，点上面的子分类换个类型试试。`;
    }
    return `「${siteName}」的「${name}」暂无内容，换个分类或切到「最近更新」。`;
  }

  /** 空状态按钮：不在「最近更新」时给一条能看到内容的退路 */
  private emptyAction(index: number): void {
    if (index === 0) {
      this.reload();
      return;
    }
    this.switchTab(0);
  }

  private reload(): void {
    const index: number = this.activeTab;
    const e: TabEntry = this.entryOf(index);
    e.items = [];
    e.clearRows();
    e.pane.page = 1;
    e.pane.pageCount = 1;
    e.pane.loaded = false;
    e.pane.errMsg = '';
    this.loadFor(index, true, true);
  }

  /* ==================== 切换 ==================== */

  /**
   * Swiper 翻到了某一页。
   *
   * 注意方向：这里是**滑动驱动状态**。用户滑到第 N 个分类 → 同步 activeTab / 二级页签 / 筛选行。
   * 反方向（点击页签）由 `.index(this.activeTab)` 驱动 Swiper，两边靠 `index === activeTab` 互不打架。
   */
  private onSwiperChange(index: number): void {
    if (index === this.activeTab) {
      return;
    }
    this.switchTab(index);
  }

  private switchTab(index: number): void {
    if (index === this.activeTab) {
      return;
    }
    this.activeTab = index;
    this.applyTab(index);
    this.ensureLoaded(index);
    this.centerTab(index);
  }

  private ensureLoaded(index: number): void {
    const e: TabEntry = this.entryOf(index);
    if (e.pane.loaded || e.pane.loading) {
      // 已经有内容（多数情况是预取好的）：只把它滚回顶部，不再请求
      try {
        e.scroller.scrollEdge(Edge.Top);
      } catch (err) {
        Log.w(TAG, `scrollEdge failed: ${err}`);
      }
      this.prefetch(index);
      return;
    }
    this.loadFor(index, true, true);
  }

  private switchSub(index: number): void {
    const i: number = this.activeTab;
    const e: TabEntry = this.entryOf(i);
    if (index === e.sub) {
      return;
    }
    e.sub = index;
    e.filters = [];
    e.pane.loaded = false;
    this.activeSub = index;
    this.selections = [];
    this.loadFor(i, true, true);
    this.centerSub(index);
  }

  private selectFilter(key: string, value: string): void {
    const i: number = this.activeTab;
    const e: TabEntry = this.entryOf(i);
    const next: FilterSel[] = [];
    let replaced: boolean = false;
    for (let n = 0; n < e.filters.length; n++) {
      const s: FilterSel = e.filters[n];
      if (s.key === key) {
        const ns: FilterSel = new FilterSel();
        ns.key = key;
        ns.value = value;
        next.push(ns);
        replaced = true;
      } else {
        next.push(s);
      }
    }
    if (!replaced) {
      const ns: FilterSel = new FilterSel();
      ns.key = key;
      ns.value = value;
      next.push(ns);
    }
    e.filters = next;
    e.pane.loaded = false;
    this.selections = next;
    this.loadFor(i, true, true);
  }

  private toggleFilters(): void {
    this.getUIContext().animateTo({ duration: FILTER_MS, curve: Curve.EaseOut }, () => {
      this.showFilters = !this.showFilters;
    });
  }

  /** 把选中的一级页签平滑滚到可视区正中（分类一多，靠后的页签就不会被挤出屏幕看不见） */
  private centerTab(index: number): void {
    try {
      this.tabScroller.scrollToIndex(index, true, ScrollAlign.CENTER);
    } catch (e) {
      Log.w(TAG, `centerTab failed: ${e}`);
    }
  }

  /** 二级分类同理 */
  private centerSub(index: number): void {
    try {
      this.subScroller.scrollToIndex(index, true, ScrollAlign.CENTER);
    } catch (e) {
      Log.w(TAG, `centerSub failed: ${e}`);
    }
  }

  /* ==================== 布局 ==================== */

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
    const cols: number = HomePage.columnsFor(inner);
    const cardW: number = Math.floor((inner - GAP * (cols - 1)) / cols);
    const posterH: number = Math.floor(cardW * 1.42);
    /**
     * ⚠️ 尺寸要写进**每个槽自己的 pane**，而不是只留在 HomePage 上：
     *    pane 是 @Observed 对象、子组件用 @ObjectLink 订阅它，尺寸才能可靠下发到
     *    Swiper 里的每一页（包括当前不在可视区的那几页）。
     */
    for (let i = 0; i < this.entries.length; i++) {
      const p: PaneState = this.entries[i].pane;
      p.columns = cols;
      p.cardW = cardW;
      p.posterH = posterH;
      this.entries[i].setRows(i);
    }
  }

  private selectedValueOf(key: string): string {
    for (let i = 0; i < this.selections.length; i++) {
      if (this.selections[i].key === key) {
        return this.selections[i].value;
      }
    }
    return '';
  }

  /* ==================== 路由 ==================== */

  private openDetail(v: VodItem): void {
    const p: DetailParams = new DetailParams();
    p.vod = v;
    this.getUIContext().getRouter().pushUrl({ url: 'features/detail/view/VideoDetailPage', params: p }).catch(() => {
      ToastUtil.show(this.getUIContext(), '无法打开详情页');
    });
  }

  private goSource(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'features/source/view/SourcePage' }).catch(() => {
      ToastUtil.show(this.getUIContext(), '无法打开源管理');
    });
  }

  private goSetting(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'features/setting/view/SettingPage' }).catch(() => {
      ToastUtil.show(this.getUIContext(), '无法打开设置页');
    });
  }

  /**
   * 首页顶部搜索按钮 → 推入独立搜索页。
   *
   * 搜索已从底部页签改为独立路由页（Index 现在只有 首页/推荐/我的 三个页签），
   * 所以这里走正常的 pushUrl；SearchPage 自带返回栏，可以退回首页。
   * 注意：SearchPage 必须已登记在 `main_pages.json`，否则 pushUrl 会失败。
   */
  private goSearch(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'features/search/view/SearchPage' }).catch(() => {
      ToastUtil.show(this.getUIContext(), '无法打开搜索页');
    });
  }

  private headerSub(): string {
    const parts: string[] = [];
    if (this.site !== undefined) {
      parts.push(this.site.name);
    } else if (this.sourceName.length > 0) {
      parts.push(this.sourceName);
    }
    // 走 @StorageProp 订阅的值，而不是现读 ConfigManager —— 见 usableSiteCount 的注释
    parts.push(`${this.usableSiteCount} 个可用源`);
    return parts.join(' · ');
  }

  /** 断点 → 列数。海报是 2:3 竖图，所以小屏也从 2 列起步（1 列视觉上空得厉害）。 */
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
