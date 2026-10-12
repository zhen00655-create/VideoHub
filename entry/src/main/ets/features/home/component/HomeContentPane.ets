import { VodItem } from '../../../commons/models/TvBoxModels';
import { VodRow } from '../../../commons/models/RowModel';
import { FilterSel } from '../../source/SiteRouter';
import { AppTheme } from '../../../commons/theme/AppTheme';
import { VodRowDataSource } from '../../../commons/datasource/BasicDataSource';
import { VodRowView } from '../../../commons/component/VodRowView';
import { VodEmptyView, VodListSkeleton } from '../../../commons/component/LoadingView';
import { Log } from '../../../commons/utils/LogUtil';

const TAG = 'HomePane';
const GAP: number = 9;
const PAD: number = AppTheme.PAGE_PADDING;

/** 数据到位时内容进场：不透明度起点（不从 0 起，避免先黑一下） */
const PANE_ALPHA_FROM: number = 0.35;
/** 数据到位时内容进场：上浮起点(vp) */
const PANE_SHIFT_FROM: number = 12;
/** 内容进场时长 */
const PANE_IN_MS: number = 320;

/**
 * 一个一级分类内容页的**可观测状态槽**。
 *
 * ⚠️⚠️ 为什么必须抽成一个 @Observed 类 + @ObjectLink，而不是像原来那样
 *      给 HomeContentPane 堆一屏 @Prop（这里踩过一次大坑）：
 *
 *   HomeContentPane 住在 Swiper 里，外层又被 ForEach 包着。用 @Prop 时，
 *   子组件拿到新值的前提是「父组件 HomePage 重新执行 build 并把值推下来」。
 *   可 Swiper 只会测量和布局**当前页 + 相邻页**，离屏页这一帧会被整个跳过 ——
 *   于是出现最坑的一种故障：**数据已经写进数据源、请求日志也打了 count=20，
 *   但页面的 hasItems 仍然是 false，界面一直停在流光骨架上**。
 *
 *   @ObjectLink 走的是完全不同的链路：@Observed 对象的属性被赋值时，
 *   它**直接通知订阅了自己的子组件标记重绘**，不经过父组件的 build。所以
 *   ①页面在可视区 → 立刻刷新；②页面还没被 Swiper 创建 → 创建时读到的
 *   已经是对象里的当前值。两条路都通向「滑过去就有内容」。
 */
@Observed
export class PaneState {
  /** 是否已完成过一次请求（用来区分「还没加载」与「加载完但没内容」） */
  loaded: boolean = false;
  /** 是否已经有可渲染的行 */
  hasItems: boolean = false;
  loading: boolean = false;
  loadingMore: boolean = false;
  page: number = 1;
  pageCount: number = 1;
  errMsg: string = '';
  /** 重新加载完成时自增，驱动本页的内容进场动效（翻页加载不触发） */
  reviveTick: number = 0;
  /** 当前列数与卡片尺寸：由 HomePage 在 onAreaChange 里统一算好后写进每个槽 */
  columns: number = 3;
  cardW: number = 110;
  posterH: number = 156;
}

/**
 * 一个一级分类的**内容槽**（数据 + 框架对象）。
 *
 * ⚠️ 为什么必须一个分类一份数据源、一份滚动位置：
 *   左右滑动要做到「手指滑到哪、哪个分类的内容就跟到哪」，就必须让相邻分类的
 *   内容同时存在于树上、跟着一起平移。若几个分类共用一份数据源，两个页面会
 *   同时订阅同一份数据 → 滑动途中看到两个一模一样的列表；而「只渲染当前分类」
 *   又只能做到「整块平移 + 松手后内容瞬变」，那正是早前手写位移方案显得
 *   生硬的根因。另外本槽自己记住二级分类与筛选选择，切走再切回来还是原样。
 *
 * ⚠️ ds / scroller 刻意留在**普通类**里（不放进 @Observed 的 PaneState）：
 *    它们是框架对象（IDataSource / Scroller），只由 HomePage 持有、在构造
 *    HomeContentPane 时一次性传入即可，引用稳定，不需要也不应该被观测包装。
 */
export class TabEntry {
  /** 该分类当前选中的二级分类下标 */
  sub: number = 0;
  /** 该分类当前的筛选选择 */
  filters: FilterSel[] = [];
  /** 当前数据对应的缓存 key（换子分类/筛选就会变） */
  key: string = '';
  items: VodItem[] = [];
  /** 在途请求代号：只有代号没被覆盖的响应才会写回 */
  seq: number = 0;
  pane: PaneState = new PaneState();
  /** 本页独立数据源（HomePage 往里写，页面用 LazyForEach 渲染） */
  ds: VodRowDataSource = new VodRowDataSource();
  /** 本页独立滚动位置 */
  scroller: Scroller = new Scroller();

  /** 按当前列数重新切行（列数变了、数据换了都要调） */
  setRows(tabIndex: number): void {
    this.ds.setItems(VodRow.chunk(this.items, this.pane.columns, `${tabIndex}_${this.key}`));
    this.pane.hasItems = this.items.length > 0;
  }

  /** 清空本页已渲染的行（重新加载前，避免旧数据与新请求之间闪一下） */
  clearRows(): void {
    this.ds.clear();
    this.pane.hasItems = false;
  }
}

/**
 * 首页内容区的一页 —— 对应一个一级分类。
 *
 * 本组件只负责「渲染」：数据由 HomePage 写进 ds，状态通过 @ObjectLink 订阅，
 * 加载完成时 HomePage 自增 reviveTick 来触发一次进场动效。
 */
@Component
export struct HomeContentPane {
  /**
   * 本页状态槽。
   * ⚠️ @ObjectLink 不允许在声明处初始化，必须由父组件传入（所以没有默认值）。
   */
  @ObjectLink @Watch('onPaneChanged') pane: PaneState;
  /** 空状态按钮文案：只与「这是第几个分类」有关，不会变，@Prop 足够 */
  @Prop emptyActionText: string = '重新加载';

  /** 本页数据源（构造时由 HomePage 一次性传入，引用稳定） */
  ds: VodRowDataSource = new VodRowDataSource();
  /** 本页滚动控制器（同上） */
  scroller: Scroller = new Scroller();

  /** 进场：内容不透明度 */
  @State paneAlpha: number = 1;
  /** 进场：内容上浮位移 */
  @State paneShift: number = 0;
  /** 上次已经播放过动效的 tick —— @Watch 会被 pane 上任何属性变化带起来，靠它去重 */
  private lastReviveTick: number = 0;

  onTapItem: (v: VodItem) => void = () => {
  };
  onEmptyAction: () => void = () => {
  };
  onReachEnd: () => void = () => {
  };
  onArea: (a: Area) => void = () => {
  };

  aboutToAppear(): void {
    this.lastReviveTick = this.pane.reviveTick;
  }

  build() {
    List({ scroller: this.scroller }) {
      if (this.pane.hasItems) {
        /* ---------------- 数据 ---------------- */
        LazyForEach(this.ds, (row: VodRow) => {
          ListItem() {
            VodRowView({
              row: row,
              cardW: this.pane.cardW,
              posterH: this.pane.posterH,
              gap: GAP,
              onTap: (v: VodItem) => {
                this.onTapItem(v);
              }
            })
          }
          .padding({ bottom: 12 })
        }, (row: VodRow) => row.key)

        if (this.pane.loadingMore) {
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

        if (this.pane.page >= this.pane.pageCount) {
          ListItem() {
            Text('— 已经到底了 —')
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 10, bottom: 20 })
          }
        }
      } else if (this.pane.loaded) {
        /* ---------------- 加载完了但没内容 ---------------- */
        ListItem() {
          VodEmptyView({
            text: '没有内容',
            hint: this.hintText(),
            actionText: this.emptyActionText,
            onAction: () => {
              this.onEmptyAction();
            }
          })
        }
      } else {
        /*
         * ---------------- 还没加载 / 正在加载 ----------------
         * ⚠️ 「还没加载」也必须走骨架而不是空状态：Swiper 只预取相邻分类，
         *    快速连滑时后一个分类可能刚被创建，此时显示「没有内容」是误报。
         */
        ForEach(this.skeletonIndexes(), (i: number) => {
          ListItem() {
            VodListSkeleton({
              cardW: this.pane.cardW,
              posterH: this.pane.posterH,
              count: this.pane.columns,
              gap: GAP
            })
          }
        }, (i: number) => `sk_${i}`)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: PAD, right: PAD, top: 6 })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .cachedCount(this.cachedRows())
    .opacity(this.paneAlpha)
    .translate({ y: this.paneShift })
    .onReachEnd(() => {
      this.onReachEnd();
    })
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.onArea(newArea);
    })
  }

  /**
   * 状态槽有变化（@Watch 会被任意属性带起来）。
   * 只有「重新加载完成」才会自增 reviveTick，翻页加载不会 —— 否则每次翻页整页都闪一下。
   */
  onPaneChanged(): void {
    if (this.pane.reviveTick === this.lastReviveTick) {
      return;
    }
    this.lastReviveTick = this.pane.reviveTick;
    this.paneAlpha = PANE_ALPHA_FROM;
    this.paneShift = PANE_SHIFT_FROM;
    try {
      this.getUIContext().animateTo({
        duration: PANE_IN_MS,
        curve: Curve.FastOutSlowIn
      }, () => {
        this.paneAlpha = 1;
        this.paneShift = 0;
      });
    } catch (err) {
      // 组件已卸载 / 没有 UIContext 时 animateTo 会抛，直接落到终态即可
      Log.w(TAG, `pane animation skipped: ${err}`);
      this.paneAlpha = 1;
      this.paneShift = 0;
    }
  }

  private hintText(): string {
    if (this.pane.errMsg.length > 0) {
      return this.pane.errMsg;
    }
    return '换个分类，或到「源管理」切换配置源';
  }

  /** List 预加载行数：多缓存一两行，滚动时下一行已经就位（滑到底才蹦出来会很顿） */
  private cachedRows(): number {
    return Math.max(4, this.pane.columns * 2);
  }

  private skeletonIndexes(): number[] {
    const out: number[] = [];
    for (let i = 0; i < 4; i++) {
      out.push(i);
    }
    return out;
  }
}
