import { common } from '@kit.AbilityKit';
import { HomePage } from '../../../features/home/view/HomePage';
import { RecommendPage } from '../../../features/recommend/view/RecommendPage';
import { MinePage } from '../../../features/mine/view/MinePage';
import { AppTheme, ThemeMode } from '../../../commons/theme/AppTheme';
import { Store } from '../../../commons/utils/StoreUtil';
import { AppSettings } from '../../../commons/utils/SettingsUtil';
import { Log } from '../../../commons/utils/LogUtil';

const TAG = 'Index';

/** 启动页停留时长（ms）。太短会闪、太长烦人；这段时间首页正在拉配置和首屏数据 */
const SPLASH_HOLD_MS = 620;
/** 启动页淡出时长（ms），要和 animateTo 的 duration 对齐 */
const SPLASH_FADE_MS = 300;

/**
 * 应用主界面：底部三页签（首页 / 推荐 / 我的）+ **应用内品牌启动页**。
 *
 * 搜索**不是页签**，它是独立路由页 `features/search/view/SearchPage`，
 * 由首页顶部搜索按钮 `router.pushUrl` 进入（SearchPage 自带返回栏）。
 * 各页签内部自行按需加载数据（HomePage / RecommendPage 会在配置就绪后拉内容），
 * 这里只负责壳与沉浸式避让。
 *
 * ⚠️ 为什么启动页画在**这里**而不是交给系统的 `startWindowIcon`：
 *   系统启动页（module.json5 的 startWindowIcon / startWindowBackground）的图标尺寸
 *   由系统按固定比例绘制，应用**改不了大小**，而且背景只能给一个纯色 ——
 *   之前就是「紫色方块图标 + #0F1115 近黑底」压在本应用的深蓝渐变上，非常割裂。
 *   现在的做法：系统启动页只留纯背景色（图标换成 8×8 透明图 `start_icon_blank`，
 *   背景色改成渐变中间调 `#141A31`），真正的品牌启动页由本页自绘 ——
 *   图标大小、文案、背景渐变全部可控，而且和 App 背景**一模一样**，切过去无缝。
 */
@Entry
@Component
struct Index {
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;
  /**
   * 订阅主题版本：AppTheme 的 getter 不是响应式的，主题切换后
   * 必须靠这个值变化把根节点标记为脏，build 重跑才会读到新色板。
   */
  @StorageProp('themeVersion') themeVersion: number = 0;

  @State currentTab: number = 0;
  /** 启动浮层是否还在树上 */
  @State splashOn: boolean = true;
  /** 启动浮层不透明度（淡出用） */
  @State splashAlpha: number = 1;
  private tabsController: TabsController = new TabsController();
  private splashFadeTimer: number = -1;

  aboutToAppear(): void {
    this.bootstrapStore();
    this.splashFadeTimer = setTimeout(() => {
      this.splashFadeTimer = -1;
      // 首页第一帧已经渲染出来了，淡出启动页（别硬切，硬切能看到界面"跳"一下）
      this.getUIContext().animateTo({ duration: SPLASH_FADE_MS, curve: Curve.EaseOut }, () => {
        this.splashAlpha = 0;
      });
      setTimeout(() => {
        this.splashOn = false;
      }, SPLASH_FADE_MS + 40);
    }, SPLASH_HOLD_MS);
  }

  aboutToDisappear(): void {
    if (this.splashFadeTimer >= 0) {
      clearTimeout(this.splashFadeTimer);
      this.splashFadeTimer = -1;
    }
  }

  /**
   * 从任何页面返回首页都会走到这里（back() 触发）。
   *
   * ⚠️ 这里是主题刷新的兜底：`AppTheme` 的 getter 不是响应式的，万一某个页面
   *    漏加 `@StorageProp('themeVersion')`，它就不会跟着主题变。用户改完主题
   *    是从设置页 back 回来的，在这里强制 bump 一次，把三个页签页整体拉齐。
   *    （不改当前模式，只是让订阅方重跑一遍 build。）
   */
  onPageShow(): void {
    AppTheme.refresh();
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Tabs({ barPosition: BarPosition.End, controller: this.tabsController, index: this.currentTab }) {
        TabContent() {
          HomePage()
        }
        .tabBar(this.tabItem(0, '首页', '🏠'))

        TabContent() {
          RecommendPage()
        }
        .tabBar(this.tabItem(1, '推荐', '✨'))

        TabContent() {
          MinePage()
        }
        .tabBar(this.tabItem(2, '我的', '👤'))
      }
      .barMode(BarMode.Fixed)
      .barHeight(54 + this.getUIContext().px2vp(this.safeBottomPx))
      .barBackgroundColor(AppTheme.TAB_BAR_BG)
      .scrollable(false)
      .animationDuration(180)
      .divider({ strokeWidth: 0.5, color: AppTheme.LINE })
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [
          [AppTheme.BG_GRAD_TOP, 0.0],
          [AppTheme.BG_GRAD_MID, 0.5],
          [AppTheme.BG_GRAD_BOTTOM, 1.0]
        ]
      })
      .width('100%')
      .height('100%')
      .onChange((index: number) => {
        this.currentTab = index;
      })

      if (this.splashOn) {
        this.splashLayer()
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 应用内品牌启动页。
   * 背景用**和主界面完全同一组渐变**，所以淡出时几乎看不出接缝；
   * 图标用 `splash_logo`（从应用图标的 foreground 抠出来的透明底版本，
   * 见 resources/base/media/splash_logo.png）。
   */
  @Builder
  splashLayer() {
    Column({ space: 16 }) {
      Image($r('app.media.splash_logo'))
        .width(176)
        .objectFit(ImageFit.Contain)
        .draggable(false)
        .interpolation(ImageInterpolation.High)

      Column({ space: 5 }) {
        Text('影视观')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .letterSpacing(2)
        Text('第三方源影视聚合 · HarmonyOS NEXT')
          .fontSize(11)
          .fontColor(AppTheme.TEXT_TERTIARY)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [
        [AppTheme.BG_GRAD_TOP, 0.0],
        [AppTheme.BG_GRAD_MID, 0.5],
        [AppTheme.BG_GRAD_BOTTOM, 1.0]
      ]
    })
    .opacity(this.splashAlpha)
    /* 启动页期间把点击挡掉，避免误触到下面的页签（淡出动画跑完就整层摘掉） */
    .hitTestBehavior(HitTestMode.Block)
  }

  @Builder
  tabItem(index: number, label: string, icon: string) {
    Column({ space: 2 }) {
      Text(icon)
        .fontSize(18)
        .opacity(this.currentTab === index ? 1 : 0.45)
      Text(label)
        .fontSize(11)
        .fontColor(this.currentTab === index ? AppTheme.ACCENT : AppTheme.TEXT_TERTIARY)
    }
    .width('100%')
    .height(54)
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: this.getUIContext().px2vp(this.safeBottomPx) })
  }

  /** 配置存储要在任何页面读 preferences 之前就绪 */
  private async bootstrapStore(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await Store.init(ctx);
      // 设置要在任何页面读取之前就绪，否则首页/播放页会先用默认值渲染一次
      await AppSettings.ensure();
      // 主题也要在这里落地：aboutToAppear 早于首帧 build，
      // 所以启动页和首页第一帧就会用上用户选的主题，不会先闪一下另一个主题。
      // setMode 内部会写 AppStorage，本页已订阅 themeVersion，会跟着重渲染。
      AppTheme.setMode(AppSettings.current().themeMode);
      Log.i(TAG, `preferences ready, theme=${AppSettings.current().themeMode === ThemeMode.Light ? 'light' : 'dark'}`);
    } catch (e) {
      Log.e(TAG, `bootstrapStore failed: ${e}`);
    }
  }
}
