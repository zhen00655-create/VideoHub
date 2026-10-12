import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EpisodeModel, PlaySourceModel, SiteModel, VodItem } from '../../../commons/models/TvBoxModels';
import { DetailParams } from '../../../commons/models/RouteParams';
import { PlayRecord } from '../../../commons/models/PlayRecordModel';
import { EpisodeRow } from '../../../commons/models/RowModel';
import { ConfigManager } from '../../source/ConfigLoader';
import { SiteRouter } from '../../source/SiteRouter';
import { PlayUrlParser } from '../../source/PlayUrlParser';
import { ParseResolver, ParseResult } from '../../source/ParseResolver';
import { AppTheme } from '../../../commons/theme/AppTheme';
import { EpisodeRowDataSource } from '../../../commons/datasource/BasicDataSource';
import { VodEmptyView } from '../../../commons/component/LoadingView';
import { PlayerGestureLayer } from '../../../commons/component/PlayerGestureLayer';
import { VolumePanelHost } from '../../../commons/component/VolumePanelHost';
import {
  PlayerControls, ASPECT_FIT, ASPECT_FILL, ASPECT_16_9, ASPECT_4_3
} from '../component/PlayerControls';
import { EpisodeDialog } from '../component/EpisodeDialog';
import { DownloadDialog } from '../component/DownloadDialog';
import { PlayDataStore } from '../../../commons/utils/PlayDataStore';
import { AppSettings, AppSettingsData } from '../../../commons/utils/SettingsUtil';
import { UrlUtil } from '../../../commons/utils/UrlUtil';
import { Log } from '../../../commons/utils/LogUtil';
import { ScreenUtil } from '../../../commons/utils/ScreenUtil';
import { BrightnessUtil } from '../../../commons/utils/BrightnessUtil';
import { VolumeUtil } from '../../../commons/utils/VolumeUtil';
import { CastUtil, CastMedia } from '../../../commons/utils/CastUtil';
import { DownloadUtil } from '../../../commons/utils/DownloadUtil';
import { AppLifecycleUtil } from '../../../commons/utils/AppLifecycleUtil';
import {
  AudioFocusUtil, FOCUS_NONE, FOCUS_PAUSE, FOCUS_RESUME, FOCUS_UNDUCK
} from '../../../commons/utils/AudioFocusUtil';
import { PlayerErrorUtil } from '../../../commons/utils/PlayerErrorUtil';
import { ShareUtil } from '../../../commons/utils/ShareUtil';
import { IntroMark, IntroMarkStore } from '../../../commons/utils/IntroMarkStore';
import { ToastUtil } from '../../../commons/utils/ToastUtil';

const TAG = 'VideoDetail';
const PAD: number = AppTheme.PAGE_PADDING;
const EP_GAP: number = 8;
/** 小窗每隔多久把进度写一次 preferences（和播放页同一套节奏） */
const MINI_SAVE_INTERVAL_MS = 10000;
/** 小窗控制条自动隐藏的等待时间 */
const MINI_HIDE_DELAY_MS = 3500;
/** 全屏时留久一点：横屏下用户多半是要拖进度条，刚唤出来就消失很难用 */
const MINI_HIDE_DELAY_FS_MS = 5000;
/** 片尾多少毫秒内算「已看完」——主判据仍是 AVPlayer 的 completed */
const MINI_END_MARGIN_MS = 8000;
/** 小窗续播 seek 的兜底等待：个别片源 seekDone 不回调，超时就强行起播 */
const MINI_RESUME_GUARD_MS = 2000;
/**
 * 控制层可见时，**横滑手势**要避开的底部保留区高度（vp）。
 * ⚠️ 现在手势层是包住控制层的**父容器**、高度固定 100%，不再做裁剪 ——
 *    这个值只作为 `bottomReservedH` 传下去，判断「本次横滑是不是从进度条那一带起手」。
 *    纵向的亮度 / 音量不受它限制。
 */
const GESTURE_BOTTOM_GAP = 100;
/**
 * 小窗 `play()` 被拒（典型 5400102 Operation not allowed）后的重试次数与间隔。
 * 起播瞬间状态还在跳，重试一次基本就落地，比直接给用户报「起播失败」强得多。
 */
const PLAY_RETRY_MAX = 1;
const PLAY_RETRY_DELAY_MS = 400;

@Entry
@Component
struct VideoDetailPage {
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  /** 订阅主题版本：AppTheme 的 getter 不是响应式的，主题切换后靠它触发重渲染 */
  @StorageProp('themeVersion') themeVersion: number = 0;

  @State vod: VodItem = new VodItem();
  @State sources: PlaySourceModel[] = [];
  @State curSource: number = 0;
  @State loading: boolean = true;
  @State errMsg: string = '';
  @State expand: boolean = false;
  @State favored: boolean = false;
  @State epCols: number = 4;
  @State resumeText: string = '';
  /** 顶部聚合进度条：0~1 */
  @State watchRatio: number = 0;
  /** 已看完集数（聚合展示用） */
  @State watchCount: number = 0;
  /** 已看完集的位图，用于把看过的集标灰 */
  @State watchedMask: string = '';

  private epDs: EpisodeRowDataSource = new EpisodeRowDataSource();
  private rows: EpisodeRow[] = [];
  private curEpisode: number = 0;
  private innerW: number = 0;
  /** 对齐到当前 sources 之后的续播点：只有点中的正是 (resumeSrc, resumeEp) 才带进度进去 */
  private resumeMs: number = 0;
  private resumeSrc: number = -1;
  private resumeEp: number = -1;
  /**
   * 续播形态：
   * 0=无记录 1=本集续播 2=本集已看完 → 续到下一集 3=全部看完（重新播放）
   */
  @State resumeKind: number = 0;

  /* ==================== 内嵌播放小窗 ==================== */
  /**
   * 点「立即播放」/选集后，在本页顶部直接出一个播放窗（不跳页），
   * 想看大屏再点窗上的「放大」进横屏播放页。这和播放页是**两个独立播放器**：
   * 小窗只负责试看，跳转前会先把它彻底释放掉，绝不会两个一起出声。
   */
  @State miniVisible: boolean = false;
  @State miniLoading: boolean = false;
  @State miniStatus: string = '';
  @State miniPlaying: boolean = false;
  @State miniShowControls: boolean = true;
  @State miniPosSec: number = 0;
  @State miniDurSec: number = 0;
  /** 片源真实宽高：surface 是拉伸填满的，必须靠它算等比尺寸，否则画面会变形 */
  @State miniW: number = 0;
  @State miniH: number = 0;
  /** 小窗容器的实测尺寸（vp），用来算画面的等比尺寸 */
  @State miniBoxW: number = 0;
  @State miniBoxH: number = 0;
  @State miniEpName: string = '';
  /** 正在拖进度条：拖动期间别让 timeUpdate 把滑块拽回去 */
  @State miniDragging: boolean = false;
  /** 拖动中预览到的时间（秒） */
  @State miniDragSec: number = 0;
  /**
   * 小窗是否已「就地放大」成全屏。
   * 放大**不跳页**——跳页必然新建播放器、重新拉流，看着就是「从头加载一遍」。
   * 这里只是把同一个 XComponent 的容器撑满屏幕 + 转横屏，播放器实例和缓冲原样保留。
   */
  @State miniFullscreen: boolean = false;
  /** 当前窗口宽高比（px），全屏时拿它撑满容器，旋转过程中会重采样纠正 */
  @State screenAspect: number = 0;

  /* ---------- 全屏控制层 / 手势层新增状态 ---------- */
  /** 已缓冲到的位置（秒） */
  @State miniBufferedSec: number = 0;
  /** 画面比例模式（ASPECT_*） */
  @State miniAspect: number = ASPECT_FIT;
  /** 全屏是否锁屏（锁上后所有手势失效，只留解锁按钮） */
  @State miniLocked: boolean = false;
  /** 手势层用的当前亮度（⚠️ 不能叫 brightness，会和 ArkUI 内置属性冲突） */
  @State miniBright: number = 0.6;
  /** 播放器音量（0~1）：手势的基准值与提示百分比都看它 */
  @State miniVolume: number = 1;
  /**
   * 系统媒体音量等级，交给根节点常驻的 VolumePanelHost —— 改它才是真的改系统音量。
   * ⚠️ 只能挂在**无条件渲染**的 Stack 上，不能跟着全屏/控制条显隐一起销毁重建。
   * （`AVPlayer.setVolume` 只改音频流相对音量，系统音量条不动，用户感觉不到。）
   * ⚠️ 初值 -1 是越界值（会被系统丢弃）；用 0 会把用户音量清零。
   */
  @State miniVolumeLevel: number = -1;
  /** 投屏：会话就绪 / 已连上远端 / 设备名 */
  @State castReady: boolean = false;
  @State casting: boolean = false;
  @State castDeviceName: string = '';
  /** 片头 / 片尾范围内时显示的跳过按钮文案 */
  @State skipIntroText: string = '';
  @State skipOutroText: string = '';
  @State hasIntroMark: boolean = false;
  @State hasOutroMark: boolean = false;
  private introMark: IntroMark = new IntroMark();
  /** 全屏控制层显示的倍速（详情页只有一个播放器，倍速跟着它走） */
  @State miniSpeed: number = 1.0;
  private miniSpeedBeforeLongPress: number = 1.0;

  private miniPlayer: media.AVPlayer | undefined = undefined;
  private miniSurfaceId: string = '';
  private miniXC: XComponentController = new XComponentController();
  /**
   * 小窗播放器的操作串行化。
   * 换集时会先 reset 旧片源、再 setMediaSource 新片源，两者都是异步的；
   * 不排队的话新的一次 setMediaSource 会被上一轮的 reset 打断，表现是「切集后黑屏不出画」。
   */
  private miniChain: Promise<void> = Promise.resolve();
  private miniSurfaceReady: boolean = false;
  private miniSrcIndex: number = 0;
  private miniEpIndex: number = 0;
  /** 待 seek 的起播位置；只消费一次 */
  private miniStartMs: number = 0;
  private miniSavedMs: number = 0;
  private miniLastSavedMs: number = 0;
  private miniReachedEnd: boolean = false;
  /** 本集是否已经自动跳过片头 / 片尾（每集只自动跳一次，见 applyMiniMarks） */
  private miniIntroAutoSkipped: boolean = false;
  private miniOutroAutoSkipped: boolean = false;
  /** 已下发续播 seek、还在等 seekDone —— 等到了才起播 */
  private miniPendingSeek: boolean = false;
  /** 已经有一个 mini play() 在飞：连续下发第二次必然拿到 5400102 */
  private miniPlayInFlight: boolean = false;
  private miniPlayRetry: number = 0;
  private miniSeekGuard: number = -1;
  private miniHideTimer: number = -1;
  private miniUrl: string = '';
  private miniHeaders: Record<string, string> | undefined = undefined;
  /** 播放完自动下一集（跟随设置页，和播放页一致） */
  @State autoNext: boolean = true;

  /* ---------- 下载 ---------- */
  /**
   * 下载进度文案（空串 = 当前没有任务）。
   * 显示在小窗顶部浮层的「下载」按钮上，比 Toast 持久、也不用额外做一个下载管理页。
   */
  @State downloadText: string = '';
  private downloadCtrl: CustomDialogController | undefined = undefined;
  /** 选集面板：全屏时也能直接拉出来（以前只能退出全屏回竖屏选） */
  private epCtrl: CustomDialogController | undefined = undefined;

  /* ---------- 前后台 / 音频焦点（小窗播放器） ---------- */
  /** 进后台前是不是在播；回前台按它决定是否恢复 */
  private miniWasPlaying: boolean = false;
  /**
   * 用户的播放意图：true = 用户想让它是播着的。
   *
   * ⚠️ 为什么不能直接看 `miniPlaying`：`onPageHide()` 会调 `pauseMini()`，
   *   而系统在**切后台时也可能**触发 `onPageHide`（就是用户反馈的「切后台偶发」的来源）。
   *   那个暂停只改播放器状态，会把 `miniPlaying` 变成 false ——
   *   再进后台处理时就读不到「刚才本来是在播的」，回前台自然也就不恢复了。
   *   所以意图单独记一份，只有**用户主动按暂停**才清掉。
   */
  private miniWantPlay: boolean = false;
  /** 被系统音频焦点中断而暂停的（来电 / 别的播放器） */
  private miniPausedByInterrupt: boolean = false;
  /** 绑在 AppLifecycleUtil 上的回调必须留引用，否则 off 不掉 */
  private readonly cbAppForeground: () => void = () => {
    this.onAppForeground();
  };
  private readonly cbAppBackground: () => void = () => {
    this.onAppBackground();
  };

  aboutToAppear(): void {
    this.readParams();
    this.load();
    // 亮度手势要有个起点
    BrightnessUtil.capture(this.getUIContext());
    this.miniBright = BrightnessUtil.current();
    // 音量手势的起点取系统当前音量；投播会话异步建
    this.syncVolumeFromSystem();
    this.setupCast();
    // 下载进度回显：任务跑在系统下载服务里，完成/失败都会回调到这里
    DownloadUtil.onProgress = (done: number, failed: number, running: number) => {
      if (running > 0) {
        this.downloadText = `下载中 ${done}/${done + failed + running}`;
      } else {
        this.downloadText = '';
        ToastUtil.show(this.getUIContext(), `下载结束：成功 ${done} 集${failed > 0 ? `，失败 ${failed} 集` : ''}`);
      }
    };
    // 前后台：onPageShow/onPageHide 只管路由，按 Home 键不触发，必须走应用级监听
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx !== undefined && ctx !== null) {
      AppLifecycleUtil.init(ctx);
      AppLifecycleUtil.onForeground(this.cbAppForeground);
      AppLifecycleUtil.onBackground(this.cbAppBackground);
    }
  }

  /* ==================== 前后台 / 音频焦点 ==================== */

  /** 切后台：小窗播放器必须停掉（否则会「切后台还在播」） */
  private onAppBackground(): void {
    this.clearMiniHideTimer();
    this.saveMiniProgress();
    const player: media.AVPlayer | undefined = this.miniPlayer;
    if (player === undefined) {
      return;
    }
    // 用「用户意图」而不是 `miniPlaying`：onPageHide 可能已经先把它暂停了（见 miniWantPlay 注释）
    this.miniWasPlaying = this.miniWantPlay;
    if (this.miniWasPlaying) {
      this.miniPlaying = false;
      this.safeMini(() => player.pause(), 'mini bg pause');
    }
    Log.i(TAG, `mini background: wasPlaying=${this.miniWasPlaying}`);
  }

  /** 回前台：把音频流压满、按需恢复播放 */
  private onAppForeground(): void {
    const player: media.AVPlayer | undefined = this.miniPlayer;
    if (player === undefined) {
      return;
    }
    AudioFocusUtil.restoreStreamVolume(player);
    this.syncVolumeFromSystem();
    if (this.miniPausedByInterrupt) {
      return;
    }
    if (this.miniWasPlaying) {
      this.miniWasPlaying = false;
      if (player.state === 'paused' || player.state === 'prepared') {
        this.miniWantPlay = true;
        this.miniPlaying = true;
        this.safeMini(() => player.play(), 'mini fg resume');
      }
    }
  }

  /** 系统音频焦点事件：来电 / 别的播放器抢焦点 */
  private onAudioFocus(kind: number): void {
    const player: media.AVPlayer | undefined = this.miniPlayer;
    if (player === undefined || kind === FOCUS_NONE) {
      return;
    }
    if (kind === FOCUS_PAUSE) {
      // 必须真的暂停，系统才会回 RESUME；否则这条流会一直哑着（「声音突然消失」）
      this.miniPausedByInterrupt = true;
      this.miniPlaying = false;
      this.safeMini(() => player.pause(), 'mini focus pause');
      return;
    }
    if (kind === FOCUS_RESUME) {
      AudioFocusUtil.restoreStreamVolume(player);
      if (this.miniPausedByInterrupt) {
        this.miniPausedByInterrupt = false;
        this.miniPlaying = true;
        this.safeMini(() => player.play(), 'mini focus resume');
      }
      return;
    }
    if (kind === FOCUS_UNDUCK) {
      this.syncVolumeFromSystem();
    }
  }

  /** 把手势层的音量基准同步成系统当前音量 */
  private syncVolumeFromSystem(): void {
    VolumeUtil.syncFromSystem();
    this.miniVolumeLevel = VolumeUtil.currentLevel();
    this.miniVolume = VolumeUtil.ratio();
  }

  /**
   * 播放器操作统一包一层。
   * `pause()/play()/seek()` 这几个是**同步抛异常**的接口，写 `safe(player.pause())`
   * 接不住（异常在进函数之前就抛了），必须传闭包进来。
   */
  private safeMini(run: () => void, what: string): void {
    try {
      run();
    } catch (e) {
      Log.w(TAG, `${what} failed: ${e}`);
    }
  }

  /**
   * 建立投播会话。详情页的播放器就是那个小窗，投屏对象自然是它。
   * 会话建不起来就不显示投屏入口。
   */
  private setupCast(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    CastUtil.onRemotePlay = () => {
      const player: media.AVPlayer | undefined = this.miniPlayer;
      if (player !== undefined && player.state === 'paused') {
        this.safeMini(() => player.play(), 'cast play');
      }
    };
    CastUtil.onRemotePause = () => {
      const player: media.AVPlayer | undefined = this.miniPlayer;
      if (player !== undefined && player.state === 'playing') {
        this.safeMini(() => player.pause(), 'cast pause');
      }
    };
    CastUtil.onRemoteStop = () => {
      const player: media.AVPlayer | undefined = this.miniPlayer;
      if (player !== undefined) {
        this.safeMini(() => player.pause(), 'cast stop');
      }
    };
    CastUtil.onRemoteSeek = (ms: number) => {
      const player: media.AVPlayer | undefined = this.miniPlayer;
      if (player !== undefined) {
        this.safeMini(() => player.seek(ms), 'cast seek');
      }
    };
    CastUtil.onDeviceChanged = (connected: boolean, name: string) => {
      this.casting = connected;
      this.castDeviceName = name;
      if (connected) {
        ToastUtil.show(this.getUIContext(), `已投屏到「${name}」，本机停止播放`);
        const player: media.AVPlayer | undefined = this.miniPlayer;
        if (player !== undefined && player.state === 'playing') {
          this.safeMini(() => player.pause(), 'cast handover');
        }
      } else {
        ToastUtil.show(this.getUIContext(), '投屏已断开');
      }
    };
    CastUtil.ensureSession(ctx).then((ok: boolean) => {
      this.castReady = ok;
      if (ok) {
        CastUtil.flushMedia().catch((e: Error) => {
          Log.w(TAG, `flushMedia failed: ${e}`);
        });
      }
    }).catch((e: Error) => {
      Log.w(TAG, `ensureSession failed: ${e}`);
    });
  }

  /** 点投屏图标：拉起系统的设备选择面板（图标颜色只听 `casting`，见 CastUtil.showPicker） */
  private openCastPicker(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    CastUtil.showPicker(ctx).catch((e: Error) => {
      Log.w(TAG, `showPicker failed: ${e}`);
    });
  }

  /** 把当前这一集的最终直链交给投播会话（投屏中换集会顺带推给远端） */
  private pushCastMedia(url: string): void {
    if (url.length === 0) {
      return;
    }
    const info: CastMedia = new CastMedia(
      `${this.vod.name}_${this.miniSrcIndex}_${this.miniEpIndex}`,
      this.vod.name,
      this.miniEpName,
      this.miniDurSec * 1000,
      url
    );
    CastUtil.setMedia(info).catch((e: Error) => {
      Log.w(TAG, `setMedia failed: ${e}`);
    });
  }

  /** 把本端播放状态报给投播会话，播控中心的按钮/进度条才不会脱节 */
  private reportCastState(playing: boolean): void {
    if (!this.castReady) {
      return;
    }
    CastUtil.setState(playing, this.miniSavedMs, this.miniSpeed).catch((e: Error) => {
      Log.w(TAG, `reportCastState failed: ${e}`);
    });
  }

  /** 从播放页返回时刷新历史：不然「继续观看」用的还是刚进这个页面时的旧进度 */
  onPageShow(): void {
    this.refreshResume();
    // 首次进页面时小窗还没起播，这里自然什么都不做；只有「被盖住又回来」才会命中
    this.resumeMiniIfPaused();
  }

  /**
   * 页面被盖住时（进播放页 / 切后台）把小窗暂停。
   * 这里**不能释放**：从后台回来、或从播放页返回后，用户多半还想接着在小窗里看。
   */
  onPageHide(): void {
    this.pauseMini();
  }

  aboutToDisappear(): void {
    this.clearMiniHideTimer();
    this.clearMiniSeekGuard();
    // 先摘前后台监听再收播放器，否则回调可能打在已经释放的 player 上
    AppLifecycleUtil.offForeground(this.cbAppForeground);
    AppLifecycleUtil.offBackground(this.cbAppBackground);
    this.saveMiniProgress();
    this.releaseMiniPlayer();
    // 别再往已经销毁的组件里写状态；下载任务本身跑在系统下载服务里，不受影响
    DownloadUtil.onProgress = () => {
    };
    // 投屏会话跟着页面一起收掉
    CastUtil.release().catch((e: Error) => {
      Log.w(TAG, `release cast failed: ${e}`);
    });
    // 页面没了就别再占着窗口的常亮标志
    this.applyKeepScreenOn(false);
    // 亮度手势改过窗口亮度的话，退出时还原
    BrightnessUtil.restore(this.getUIContext());
    // 页面都销毁了还留在横屏会很尴尬，兜底转回来
    this.exitMiniFullscreen();
  }

  build() {
    Column() {
      /* ==================== 顶部播放窗（常驻） ====================
       * 进详情页就是一个 16:9 的播放窗，**进去就自动起播**（不再放播放按钮）；
       * 数据还没到位的这一小会儿先铺封面顶上，画面到了就换成 XComponent。
       * 窗底常驻一条控制条（暂停 · 时间 · 进度 · 时长 · 全屏），
       * 返回 / 标题 / 收藏浮在画面上 —— 排布对齐参考图。
       *
       * 播放窗上下各压一条纯黑"边"：上面那条让开状态栏（不然状态栏的时间和电量
       * 直接压在画面上，非常难看），下面那条把画面和片名信息拉开距离。
       * 用独立的 Row 而不是给 Stack 加 padding —— padding 会把 aspectRatio 内的
       * 可用高度吃掉，画面会跟着缩水；margin 又留不出黑色。 */
      Row()
        .width('100%')
        .height(this.miniFullscreen ? 0 : this.getUIContext().px2vp(this.safeTopPx) + 10)
        .backgroundColor('#000000')

      Stack({ alignContent: Alignment.Center }) {
        /*
         * ==================== 统一手势层 = 画面 + 控制层的**父容器**（全屏时接管） ====================
         * （2026-10-12 终版，用户 + 华为官方文档双确认）
         *
         * 官方《多层级手势事件》给的是**父子**关系：
         *   · 响应优先级 1 —— **父子组件均绑定同一类手势时，子组件优先于父组件触发**；
         *   · `HitTestMode.Default` —— 自身如果命中会阻塞兄弟组件，**但是不阻塞子组件**；
         *   · 触摸测试「自上而下遍历……结果逐级向上冒泡至父组件」→ 父容器永远在响应链上。
         *
         * 所以把整个播放窗内容（画面 / 压暗 / 状态层 / 控制层 / 小窗控制条）都作为插槽塞进来：
         * 按钮是**子**、手势是**父** —— 按钮的 onClick 天然优先，空白处才轮到手势层。
         * ⚠️⚠️ 别再把它拆回 Stack 里的兄弟层（兄弟只按 z 序二选一，前面五六版都栽在这）。
         * ⚠️ 竖屏小窗要关掉手势：`active` 传 `miniFullscreen`，那时竖屏自己那层的
         *    onClick（本组件的子节点）负责显隐控制条。
         */
        PlayerGestureLayer({
          active: this.miniFullscreen,
          locked: this.miniLocked,
          durationSec: this.miniDurSec,
          positionSec: this.miniPosSec,
          areaW: this.miniBoxW,
          areaH: this.miniBoxH,
          brightLevel: this.miniBright,
          volume: this.miniVolume,
          // 控制层可见时横滑避开进度条那一带（纵向亮度/音量不受限）
          bottomReservedH: (this.miniFullscreen && this.miniShowControls) ? GESTURE_BOTTOM_GAP : 0,
          onSingleTap: () => {
            this.toggleMiniControls();
          },
          onDoubleTap: () => {
            this.toggleMiniPlay();
          },
          onLongPressStart: () => {
            this.startMiniLongPressSpeed();
          },
          onLongPressEnd: () => {
            this.endMiniLongPressSpeed();
          },
          onSeekPreview: (sec: number) => {
            this.miniPosSec = sec;
          },
          onSeekTo: (sec: number) => {
            this.seekMiniToSec(sec);
          },
          onSeekCancel: () => {
          },
          onBrightness: (v: number) => {
            this.miniBright = v;
            BrightnessUtil.set(this.getUIContext(), v);
          },
          onVolume: (v: number) => {
            this.miniVolume = v;
            this.applyMiniVolume(v);
          }
        }) {
          /*
           * 系统音量面板宿主（常驻，只此一处）。
           * 它内部是 UIExtensionComponent，会吃掉整条触摸事件（见 VolumePanelHost 头部注释），
           * 整棵子树都用 BLOCK_DESCENDANTS 关掉触摸测试 —— 别改成 None。
           */
          VolumePanelHost({ volumeLevel: this.miniVolumeLevel })

          /* --- 1. 画面层 --- */
          if (this.miniVisible) {
            XComponent({
              id: 'detail_mini_video',
              type: XComponentType.SURFACE,
              controller: this.miniXC
            })
              .onLoad(() => {
                this.miniSurfaceId = this.miniXC.getXComponentSurfaceId();
                this.miniSurfaceReady = true;
                Log.i(TAG, `mini surfaceId=${this.miniSurfaceId}`);
                this.maybeMiniStart();
              })
              .onDestroy(() => {
                // 正常不该走到这（放大只是改容器尺寸，不摘节点）；真出现了就是画面黑掉的原因
                Log.i(TAG, 'mini xcomponent destroyed');
                this.miniSurfaceId = '';
                this.miniSurfaceReady = false;
              })
              .width(this.miniRenderW())
              .height(this.miniRenderH())
          } else {
            Image(this.vod.pic)
              .alt($r('app.media.background'))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .backgroundColor(AppTheme.PLACEHOLDER)
          }

          /* --- 2. 上下压暗：白色浮层要有底才看得清 --- */
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              direction: GradientDirection.Bottom,
              colors: [
                ['rgba(0,0,0,0.42)', 0.0],
                ['rgba(0,0,0,0.02)', 0.28],
                ['rgba(0,0,0,0.02)', 0.66],
                ['rgba(0,0,0,0.46)', 1.0]
              ]
            })

          /* --- 3. 交互层 ---
           * 全屏：整套手势交给 PlayerGestureLayer（单击显隐控制层 / 双击暂停继续 /
           *       长按 2x 快进 / 横滑快进快退 / 左半屏竖滑亮度 / 右半屏竖滑音量），
           *       和横屏播放页共用同一个组件，手感一致。
           * 竖屏小窗：只保留「点一下唤出控制条 / 未起播时重试起播」。 */
          /* 竖屏小窗：只保留「点一下唤出控制条 / 未起播时重试起播」。
           * 全屏的手势层已移到 Stack 最上层（见 Stack 末尾说明）—— 放在这里会被控制层吃掉触摸。 */
          if (!this.miniFullscreen) {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('#00000000')
              .onClick(() => {
                if (!this.miniVisible) {
                  // 自动起播失败的兜底：点一下重新起播
                  this.playAt(this.curSource, this.curEpisode, true);
                  return;
                }
                this.toggleMiniControls();
              })
          }

          /* --- 4. 状态层：解析中 / 报错 --- */
          this.miniStatusLayer()

          /* --- 5. 全屏：用和横屏播放页同一套控制层；竖屏小窗：保留原来的浮层 + 控制条 --- */
          if (this.miniFullscreen) {

            if (this.miniShowControls || this.miniLocked) {
              PlayerControls({
                title: this.vod.name,
                epName: this.miniEpName,
                playing: this.miniPlaying,
                isFullscreen: true,
                positionSec: this.miniPosSec,
                durationSec: this.miniDurSec,
                bufferedSec: this.miniBufferedSec,
                speed: this.miniSpeed,
                statusText: this.miniStatus,
                sourceName: this.currentSourceName(),
                epCount: this.currentSourceEps().length,
                epIndex: this.miniEpIndex,
                autoNext: this.autoNext,
                quality: '',
                hasTracks: false,
                aspectMode: this.miniAspect,
                locked: this.miniLocked,
                skipIntroText: this.skipIntroText,
                skipOutroText: this.skipOutroText,
                hasIntroMark: this.hasIntroMark,
                hasOutroMark: this.hasOutroMark,
                castReady: this.castReady,
                casting: this.casting,
                castDeviceName: this.castDeviceName,
                onToggleLock: () => {
                  this.toggleMiniLock();
                },
                onAspect: (mode: number) => {
                  this.miniAspect = mode;
                },
                onShare: () => {
                  this.shareMini();
                },
                onCast: () => {
                  this.openCastPicker();
                },
                onMarkIntro: () => {
                  this.markMiniIntro();
                },
                onMarkOutro: () => {
                  this.markMiniOutro();
                },
                onSkipIntro: () => {
                  this.seekMiniToSec(this.introMark.introEndSec);
                },
                onSkipOutro: () => {
                  this.playAt(this.miniSrcIndex, this.miniEpIndex + 1, false);
                },
                onToggleAutoNext: () => {
                  this.toggleAutoNext();
                },
                onOpenTracks: () => {
                  ToastUtil.show(this.getUIContext(), '这个源没有可切换的字幕/音轨');
                },
                onBack: () => {
                  this.exitMiniFullscreen();
                },
                onPlayPause: () => {
                  this.toggleMiniPlay();
                },
                onSeek: (sec: number) => {
                  this.seekMiniToSec(sec);
                },
                onSeekPreview: (sec: number) => {
                  this.miniPosSec = sec;
                },
                onToggleFullscreen: () => {
                  this.exitMiniFullscreen();
                },
                onOpenEpisodes: () => {
                  // 直接在本屏右侧拉出选集面板，不再「退出全屏才让选」
                  this.openEpisodeDialog();
                },
                onPrev: () => {
                  this.playAt(this.miniSrcIndex, this.miniEpIndex - 1, false);
                },
                onNext: () => {
                  this.playAt(this.miniSrcIndex, this.miniEpIndex + 1, false);
                },
                onSpeed: (v: number) => {
                  this.changeMiniSpeed(v);
                },
                onToggleControls: () => {
                  this.toggleMiniControls();
                }
              })
                .width('100%')
                .height('100%')
            }
          } else {
            /* --- 5b. 顶部浮层：返回 + 标题 + 收藏 / 投屏 / 下载 ---
             * ⚠️ hitTestBehavior 规矩（和 PlayerControls 里那套一致）：
             *   容器 `None`、纯文字 `BLOCK_DESCENDANTS`、能点的圆按钮保持 `Default`。
             *   否则浮层会挡住下层的「点一下唤出/收起控制条」。 */
          Column() {
            Row({ space: 6 }) {
              Text(this.miniFullscreen ? '✕' : '‹')
                .fontSize(this.miniFullscreen ? 18 : 26)
                .fontColor('#FFFFFF')
                .width(36)
                .height(36)
                .textAlign(TextAlign.Center)
                .backgroundColor('rgba(0,0,0,0.32)')
                .borderRadius(18)
                .onClick(() => {
                  // 全屏时返回先「退出全屏」，而不是直接把这个详情页关掉
                  if (this.miniFullscreen) {
                    this.exitMiniFullscreen();
                  } else {
                    this.getUIContext().getRouter().back();
                  }
                })
              Text(this.vod.name.length > 0 ? this.vod.name : '详情')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .margin({ left: 8 })
                .textShadow({ radius: 4, color: '#99000000', offsetX: 0, offsetY: 1 })
                .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
              Text(this.favored ? '♥ 已收藏' : '♡ 收藏')
                .fontSize(12)
                .fontColor('#FFFFFF')
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor('rgba(0,0,0,0.32)')
                .borderRadius(AppTheme.RADIUS_PILL)
                .onClick(() => {
                  this.toggleFavorite();
                })

              /* 投屏：**自绘图标** + 拉起系统设备面板。
                 ⚠️ 别换回系统的 `AVCastPicker`：它的红色 active 态由系统决定，
                 插蓝牙耳机时某些机型也会变红，而耳机不该算投屏（见 CastUtil.showPicker）。 */
              if (this.castReady) {
                Row() {
                  this.miniIconImg(this.casting ? $r('app.media.player_ic_cast_on')
                    : $r('app.media.player_ic_cast'), 22)
                }
                .width(36)
                .height(36)
                .justifyContent(FlexAlign.Center)
                .backgroundColor('rgba(0,0,0,0.32)')
                .borderRadius(18)
                .onClick(() => {
                  this.openCastPicker();
                })
              }

              /* 下载：下载中就地变成进度胶囊，点它还能继续加集 */
              Row() {
                if (this.downloadText.length > 0) {
                  Text(this.downloadText)
                    .fontSize(10)
                    .fontColor('#FFFFFF')
                } else {
                  this.miniIconImg($r('app.media.player_ic_download'), 22)
                }
              }
              .width(this.downloadText.length > 0 ? 62 : 36)
              .height(36)
              .justifyContent(FlexAlign.Center)
              .backgroundColor('rgba(0,0,0,0.32)')
              .borderRadius(18)
              .onClick(() => {
                this.openDownloadDialog();
              })
            }
            .width('100%')
            .padding({
              left: this.miniFullscreen ? 26 : 8,
              right: this.miniFullscreen ? 26 : PAD,
              top: 6,
              bottom: 6
            })
            .hitTestBehavior(HitTestMode.None)
            Row()
              .width('100%')
              .layoutWeight(1)
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .height('100%')
          // 竖屏时播放窗上方已经有黑边让开状态栏了，这里不用再让一次
          .padding({ top: this.miniFullscreen ? 10 : 6 })
          // 全屏时标题/收藏要跟着控制条一起消失，否则全屏画面永远挂着一条标题栏
          .visibility((!this.miniFullscreen || this.miniShowControls) ? Visibility.Visible : Visibility.None)
          .hitTestBehavior(HitTestMode.None)

          /* --- 6. 底部控制条（竖屏小窗专用；全屏走上面的 PlayerControls） --- */
          Column() {
            Row()
              .width('100%')
              .layoutWeight(1)
              .hitTestBehavior(HitTestMode.None)
            if (this.miniShowControls || !this.miniVisible) {
              this.miniControlBar()
            }
          }
          .width('100%')
          .height('100%')
          .padding({ bottom: 0 })
          .hitTestBehavior(HitTestMode.None)
          }

        /* ==================== 手势层插槽内容到此结束（它是 PlayerGestureLayer 的子节点） ==================== */
        }
      }
      .width('100%')
      .aspectRatio(this.miniBoxRatio())
      .backgroundColor('#000000')
      .clip(true)
      .onAreaChange((oldArea: Area, newArea: Area) => {
        const w: number = newArea.width as number;
        const h: number = newArea.height as number;
        if (Math.abs(w - this.miniBoxW) > 0.5 || Math.abs(h - this.miniBoxH) > 0.5) {
          this.miniBoxW = w;
          this.miniBoxH = h;
        }
      })

      /* 画面与片名之间的黑边（和上面那条连成一体，把播放区框出来） */
      Row()
        .width('100%')
        .height(this.miniFullscreen ? 0 : 12)
        .backgroundColor('#000000')

      /* 主体：全屏时整块让位给播放窗（Visibility.None 连占位都省了） */
      List() {
        /* --- 信息头（封面已经放到上面的播放窗里了，这里只留文字，避免重复） --- */
        ListItem() {
          Column({ space: 7 }) {
            Row() {
              Text(this.vod.name)
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppTheme.TEXT_PRIMARY)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (this.vod.remarks.length > 0) {
                Text(this.vod.remarks)
                  .fontSize(11)
                  .fontColor(AppTheme.TEXT_SECONDARY)
                  .backgroundColor(AppTheme.CARD)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .borderRadius(4)
                  .margin({ left: 8 })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Row({ space: 10 }) {
              if (this.vod.score.length > 0 && !isNaN(parseFloat(this.vod.score))) {
                Text(`${parseFloat(this.vod.score).toFixed(1)} 分`)
                  .fontSize(13)
                  .fontColor(AppTheme.GOLD)
                  .fontWeight(FontWeight.Bold)
              }
              Text(this.metaLine())
                .fontSize(12)
                .fontColor(AppTheme.TEXT_SECONDARY)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')

            Text(`来源：${this.vod.siteName} · ${this.currentSourceName()}`)
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            Row({ space: 10 }) {
              Text(this.playButtonText())
                .fontSize(14)
                .fontColor('#FFFFFF')
                .backgroundColor(AppTheme.ACCENT)
                .padding({ left: 22, right: 22, top: 9, bottom: 9 })
                .borderRadius(AppTheme.RADIUS_PILL)
                .onClick(() => {
                  this.playAt(this.curSource, this.curEpisode, true);
                })
              Text(`${this.totalEpisodes()} 集`)
                .fontSize(12)
                .fontColor(AppTheme.TEXT_SECONDARY)
                .padding({ top: 9, bottom: 9 })
            }
            .margin({ top: 2 })

            if (this.resumeText.length > 0) {
              Text(this.resumeText)
                .fontSize(11)
                .fontColor(AppTheme.TEXT_TERTIARY)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .padding({ bottom: 14 })

        /* --- 观看进度聚合（多集连播后整部剧的进度） --- */
        if (this.watchRatio > 0) {
          ListItem() {
            Column({ space: 6 }) {
              Row() {
                Text('观看进度')
                  .fontSize(12)
                  .fontColor(AppTheme.TEXT_SECONDARY)
                Blank()
                Text(this.progressSummary())
                  .fontSize(11)
                  .fontColor(AppTheme.TEXT_TERTIARY)
              }
              .width('100%')

              Stack({ alignContent: Alignment.Start }) {
                Row()
                  .width('100%')
                  .height(4)
                  .backgroundColor(AppTheme.CARD)
                  .borderRadius(2)
                Row()
                  .width(`${Math.round(this.watchRatio * 100)}%`)
                  .height(4)
                  .backgroundColor(AppTheme.ACCENT)
                  .borderRadius(2)
              }
              .width('100%')
              .height(4)
            }
            .width('100%')
            .padding({ bottom: 14 })
          }
        }

        /* --- 加载 / 错误 --- */
        if (this.loading) {
          ListItem() {
            Column({ space: 12 }) {
              LoadingProgress()
                .width(28)
                .height(28)
                .color(AppTheme.ACCENT)
              Text('正在获取播放地址…')
                .fontSize(12)
                .fontColor(AppTheme.TEXT_TERTIARY)
            }
            .width('100%')
            .height(120)
            .justifyContent(FlexAlign.Center)
          }
        } else if (this.sources.length === 0) {
          ListItem() {
            VodEmptyView({
              text: '没有拿到播放地址',
              hint: this.errMsg.length > 0 ? this.errMsg : '该片源可能已失效，试试换一个资源站',
              actionText: '重新获取',
              onAction: () => {
                this.load();
              }
            })
          }
        } else {
          /* --- 线路选择 --- */
          if (this.sources.length > 1) {
            ListItem() {
              Column() {
                Text('播放线路')
                  .fontSize(13)
                  .fontColor(AppTheme.TEXT_SECONDARY)
                  .width('100%')
                  .margin({ bottom: 8 })
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.sources, (s: PlaySourceModel, idx: number) => {
                    Text(`${s.name}(${s.episodes.length})`)
                      .fontSize(12)
                      .fontColor(this.curSource === idx ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
                      .backgroundColor(this.curSource === idx ? AppTheme.ACCENT : AppTheme.CARD)
                      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                      .borderRadius(AppTheme.RADIUS_PILL)
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        this.switchSource(idx);
                      })
                  }, (s: PlaySourceModel, idx: number) => `ds_${idx}_${s.name}`)
                }
                .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding({ bottom: 10 })
            }
          }

          /* --- 选集标题 --- */
          ListItem() {
            Row() {
              Text('选集')
                .fontSize(13)
                .fontColor(AppTheme.TEXT_SECONDARY)
              Text(` · ${this.currentSourceName()} ${this.totalEpisodes()} 集`)
                .fontSize(12)
                .fontColor(AppTheme.TEXT_TERTIARY)
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ bottom: 8 })
          }

          /* --- 选集网格 --- */
          LazyForEach(this.epDs, (row: EpisodeRow) => {
            ListItem() {
              Row({ space: EP_GAP }) {
                ForEach(row.items, (ep: EpisodeModel) => {
                  Text(ep.name)
                    .fontSize(12)
                    .fontColor(this.epTextColor(ep.index))
                    .backgroundColor(this.epBgColor(ep.index))
                    .textAlign(TextAlign.Center)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .height(38)
                    .layoutWeight(1)
                    .borderRadius(8)
                    .onClick(() => {
                      this.playAt(this.curSource, ep.index, true);
                    })
                }, (ep: EpisodeModel) => `d_ep_${this.curSource}_${ep.index}_${ep.name}_${this.isWatchedEp(ep.index) ? 1 : 0}`)
                if (row.items.length < this.epCols) {
                  ForEach(this.fillers(row.items.length), (f: number) => {
                    Column()
                      .height(38)
                      .layoutWeight(1)
                  }, (f: number) => `df_${f}_${row.key}`)
                }
              }
              .width('100%')
              .padding({ bottom: EP_GAP })
            }
          }, (row: EpisodeRow) => row.key)

          /* --- 简介 --- */
          if (this.vod.content.length > 0) {
            ListItem() {
              Column() {
                Text('简介')
                  .fontSize(13)
                  .fontColor(AppTheme.TEXT_SECONDARY)
                  .width('100%')
                  .margin({ top: 6, bottom: 8 })
                Text(this.vod.content)
                  .fontSize(13)
                  .fontColor(AppTheme.TEXT_TERTIARY)
                  .lineHeight(20)
                  .maxLines(this.expand ? 999 : 3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(this.expand ? '收起' : '展开')
                  .fontSize(12)
                  .fontColor(AppTheme.ACCENT)
                  .margin({ top: 6 })
                  .onClick(() => {
                    this.expand = !this.expand;
                  })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            .padding({ top: 8, bottom: 30 })
          }
        }
      }
      .visibility(this.miniFullscreen ? Visibility.None : Visibility.Visible)
      .layoutWeight(1)
      .width('100%')
      .padding({ left: PAD, right: PAD, top: 10 })
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
    /* 顶部不再留安全区：播放窗要顶到屏幕最上沿（沉浸式），
       状态栏那一段由窗内的返回浮层自己让开 */
    .padding({ bottom: this.miniFullscreen ? 0 : this.getUIContext().px2vp(this.safeBottomPx()) })
  }

  /**
   * 全屏时按返回键：先退出全屏，不要直接把这个详情页关掉。
   * 返回 true = 这次返回事件已被消费。
   */
  onBackPress(): boolean {
    if (this.miniFullscreen) {
      // 锁屏状态下返回键先解锁，避免误退出全屏
      if (this.miniLocked) {
        this.toggleMiniLock();
        return true;
      }
      this.exitMiniFullscreen();
      return true;
    }
    return false;
  }

  /**
   * 画面中央的等待文案。
   * miniUrl 一填上就说明地址解析完了，后面全是 prepare 缓冲，别再说「正在解析地址」。
   */
  private miniLoadingText(): string {
    return this.miniUrl.length > 0 ? '缓冲中…' : `正在解析播放地址… ${this.miniEpName}`;
  }

  /** 画面中央的解析提示 / 错误提示（没有就不占位） */
  @Builder
  miniStatusLayer() {
    if (this.miniStatus.length > 0) {
      Text(this.miniStatus)
        .fontSize(12)
        .fontColor('#FFB4B4')
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .margin({ left: 24, right: 24 })
        .backgroundColor('rgba(0,0,0,0.55)')
        .borderRadius(8)
        .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
    } else if (this.miniLoading) {
      Column({ space: 8 }) {
        LoadingProgress()
          .width(26)
          .height(26)
          .color('#FFFFFF')
        Text(this.miniLoadingText())
          .fontSize(11)
          .fontColor('#E3E7EF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
    }
  }

  /*
   * 小窗控制条图标。与 PlayerControls 保持一致：用 `Image` 渲染
   * `resources/base/media/player_ic_*.svg`，不再自绘 Path ——
   * `Shape().viewPort()` 不缩放内容、`Path().commands()` 的坐标被按 px 解释，
   * 两者在真机上都渲染不出正确尺寸（详见 PlayerControls 里的注释）。
   */

  /** 小窗控制条图标（SVG 资源） */
  @Builder
  miniIconImg(res: Resource, size: number) {
    Image(res)
      .width(size)
      .height(size)
      .objectFit(ImageFit.Contain)
      .draggable(false)
      .interpolation(ImageInterpolation.High)
  }

  /**
   * 窗底常驻控制条（竖屏小窗专用）：暂停/播放 · 当前时间 · 进度条（可拖） · 总时长 · 全屏。
   * 全屏时改用 PlayerControls（和横屏播放页同一套），所以这里只管竖屏那一档。
   * 未起播时只显示封面和播放键，这里各项保持初始值。
   */
  @Builder
  miniControlBar() {
    Row({ space: 10 }) {
      Row() {
        if (this.miniPlaying) {
          this.miniIconImg($r('app.media.player_ic_pause'), 26)
        } else {
          this.miniIconImg($r('app.media.player_ic_play'), 26)
        }
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.toggleMiniPlay();
      })

      Text(UrlUtil.formatTime(this.miniDragging ? this.miniDragSec : this.miniPosSec))
        .fontSize(11)
        .fontColor('#E3E7EF')
        .width(42)
        .textAlign(TextAlign.Center)

      Slider({
        value: this.miniSliderValue(),
        min: 0,
        max: 100,
        step: 0.1
      })
        .layoutWeight(1)
        .trackThickness(4)
        .trackColor('rgba(255,255,255,0.32)')
        .selectedColor(AppTheme.ACCENT)
        .blockColor('#FFFFFF')
        .blockSize({ width: 13, height: 13 })
        .enabled(this.miniVisible && this.miniDurSec > 0)
        .onChange((value: number, mode: SliderChangeMode) => {
          this.onMiniSlider(value, mode);
        })

      Text(UrlUtil.formatTime(this.miniDurSec))
        .fontSize(11)
        .fontColor('#E3E7EF')
        .width(42)
        .textAlign(TextAlign.Center)

      Row() {
        this.miniIconImg(this.miniFullscreen
          ? $r('app.media.player_ic_shrink')
          : $r('app.media.player_ic_expand'), 26)
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        if (this.miniFullscreen) {
          this.exitMiniFullscreen();
        } else {
          this.expandMini();
        }
      })
    }
    .width('100%')
    .height(50)
    .padding({ left: this.miniFullscreen ? 26 : 10, right: this.miniFullscreen ? 26 : 10 })
    .backgroundColor('rgba(0,0,0,0.42)')
    // 控制条自己吃掉落到它身上的触摸事件：父层是 Transparent（让空白处点得穿），
    // 不在这里截住的话，Slider 的拖动手势会和下层的「点击唤出」竞争，进度条就拖不动
    .hitTestBehavior(HitTestMode.Default)
  }

  /* ==================== 逻辑 ==================== */

  private readParams(): void {
    try {
      const raw: Object = this.getUIContext().getRouter().getParams();
      if (raw === undefined || raw === null) {
        return;
      }
      const p: DetailParams = raw as DetailParams;
      if (p.vod !== undefined && p.vod !== null) {
        this.vod = p.vod;
      }
    } catch (e) {
      Log.w(TAG, `readParams failed: ${e}`);
    }
  }

  /* ==================== 内嵌播放小窗 ==================== */

  /**
   * 打开小窗并开始解析地址。
   *
   * 只解析、不立刻起播：XComponent 是 miniVisible 变 true 之后才挂上去的，
   * surfaceId 要等 onLoad 回调才拿得到。所以真正的起播统一由 maybeMiniStart() 闸门触发，
   * 两边（表面就绪 / 地址就绪）谁后到谁负责启动。
   */
  private openMini(srcIndex: number, epIndex: number, startMs: number): void {
    const alreadyOpen: boolean = this.miniVisible;
    this.miniSrcIndex = srcIndex;
    this.miniEpIndex = epIndex;
    this.miniStartMs = startMs;
    this.miniSavedMs = startMs;
    this.miniLastSavedMs = startMs;
    this.miniReachedEnd = false;
    // 新一集重新给片头/片尾自动跳过一次机会
    this.miniIntroAutoSkipped = false;
    this.miniOutroAutoSkipped = false;
    this.miniPosSec = Math.floor(startMs / 1000);
    this.miniDurSec = 0;
    // 新一集的缓冲从零起（bufferingUpdate 只在变大时更新，不清会被上一集的值顶住）
    this.miniBufferedSec = 0;
    this.skipIntroText = '';
    this.skipOutroText = '';
    // 保留上一集的宽高比：同一部片的比例基本不变，清零会让小窗先跳一下再纠正
    this.miniPlaying = false;
    this.miniStatus = '';
    this.miniLoading = true;
    this.miniShowControls = true;
    this.miniEpName = this.epNameOf(srcIndex, epIndex);
    this.miniUrl = '';
    this.miniHeaders = undefined;
    this.miniVisible = true;
    if (!alreadyOpen) {
      // 新挂上来的 XComponent 还没就绪，等它自己的 onLoad
      this.miniSurfaceReady = false;
    }
    // 换集时先把上一集停掉，别让旧画面继续放着；上一轮没落地的续播 seek 也一起作废
    this.clearMiniSeekGuard();
    this.miniPendingSeek = false;
    this.stopMiniPlayback();
    this.scheduleMiniHide();
    this.resolveMini(srcIndex, epIndex);
  }

  /**
   * 解析这一集的真实播放地址。
   * 和播放页共用同一个 ParseResolver：直连的片子给直链，
   * 需要解析的走配置里的解析器 —— 绝不在详情页自己造一套取源逻辑。
   */
  private async resolveMini(srcIndex: number, epIndex: number): Promise<void> {
    if (srcIndex < 0 || srcIndex >= this.sources.length) {
      return;
    }
    const eps: EpisodeModel[] = this.sources[srcIndex].episodes;
    if (epIndex < 0 || epIndex >= eps.length) {
      return;
    }
    const ep: EpisodeModel = eps[epIndex];
    let pr: ParseResult = new ParseResult();
    try {
      pr = await ParseResolver.resolve(ep.url, this.siteOf(), ConfigManager.get().parses, -1);
    } catch (e) {
      pr.ok = false;
      pr.error = `${e}`;
    }
    // 解析期间用户又换了集 / 收了小窗，这份结果已经过期
    if (!this.miniVisible || this.miniSrcIndex !== srcIndex || this.miniEpIndex !== epIndex) {
      return;
    }
    if (!pr.ok || pr.url.length === 0) {
      this.miniLoading = false;
      this.miniStatus = '这个来源解析不出播放地址，试试换线路，或点「放大」进播放页重试';
      Log.w(TAG, `mini parse failed: ${pr.error}`);
      return;
    }
    this.miniUrl = pr.url;
    this.miniHeaders = pr.headers;
    this.maybeMiniStart();
  }

  /** 起播闸门：表面就绪 + 地址已解析，两个条件齐了才起播 */
  private maybeMiniStart(): void {
    if (!this.miniVisible || !this.miniSurfaceReady) {
      return;
    }
    if (this.miniUrl.length === 0) {
      return;
    }
    this.startMiniPlayback();
  }

  private startMiniPlayback(): void {
    const url: string = this.miniUrl;
    const headers: Record<string, string> | undefined = this.miniHeaders;
    const surface: string = this.miniSurfaceId;
    if (surface.length === 0 || url.length === 0) {
      return;
    }
    this.enqueueMini(() => this.doStartMini(url, headers, surface));
  }

  private async doStartMini(url: string, headers: Record<string, string> | undefined,
    surface: string): Promise<void> {
    // 排队期间小窗可能被关掉或换了集，进来先确认这份请求还有效
    if (!this.miniVisible || this.miniUrl !== url || this.miniSurfaceId !== surface) {
      return;
    }
    try {
      const player: media.AVPlayer = await this.ensureMiniPlayer();
      if (player.state !== 'idle') {
        await player.reset();
      }
      const src: media.MediaSource = headers !== undefined
        ? media.createMediaSourceWithUrl(url, headers)
        : media.createMediaSourceWithUrl(url);
      await player.setMediaSource(src);
      Log.i(TAG, `mini setMediaSource ok, state=${player.state}`);
      // 拿到最终直链了，登记到投播会话（投屏中换集会顺带推给远端设备）
      this.pushCastMedia(url);
    } catch (e) {
      const err = e as BusinessError;
      this.miniLoading = false;
      this.miniStatus = `播放失败 ${err.code}`;
      Log.e(TAG, `mini start failed ${err.code} ${err.message}`);
    }
  }

  private enqueueMini(job: () => Promise<void>): void {
    this.miniChain = this.miniChain.then(job).catch((e: Error) => {
      Log.w(TAG, `mini job failed: ${e}`);
    });
  }

  private async ensureMiniPlayer(): Promise<media.AVPlayer> {
    if (this.miniPlayer !== undefined) {
      return this.miniPlayer;
    }
    const player: media.AVPlayer = await media.createAVPlayer();
    player.on('stateChange', (state: media.AVPlayerState) => {
      this.onMiniState(state, player);
    });
    player.on('timeUpdate', (time: number) => {
      this.miniPosSec = Math.floor(time / 1000);
      this.miniSavedMs = time;
      // 「跳过片头/片尾」按钮跟着播放位置走
      this.refreshMiniSkip();
      // 片头/片尾标记自动生效（标了就要自动跳，而不是只弹胶囊等手点）
      this.applyMiniMarks();
      // 周期落盘：只靠 aboutToDisappear 的话，被系统杀进程就丢进度了
      if (time - this.miniLastSavedMs >= MINI_SAVE_INTERVAL_MS) {
        this.miniLastSavedMs = time;
        this.saveMiniProgress();
      }
    });
    // 缓冲进度：CACHED_DURATION 是已缓存到的时间（毫秒）
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (infoType === media.BufferingInfoType.CACHED_DURATION) {
        const sec: number = Math.floor(value / 1000);
        if (sec > this.miniBufferedSec) {
          this.miniBufferedSec = sec;
        }
      }
    });
    player.on('durationUpdate', (duration: number) => {
      this.miniDurSec = Math.floor(duration / 1000);
    });
    // 续播的 seek 落地了才真正起播（见 onMiniState）
    player.on('seekDone', (pos: number) => {
      if (!this.miniPendingSeek) {
        return;
      }
      this.miniPendingSeek = false;
      this.clearMiniSeekGuard();
      this.miniSavedMs = pos;
      this.miniLastSavedMs = pos;
      this.miniPosSec = Math.floor(pos / 1000);
      this.doMiniPlay(player);
    });
    // 片源真实分辨率：surface 是拉伸填满的，拿到它才能把画面摆正
    player.on('videoSizeChange', (width: number, height: number) => {
      if (width > 0 && height > 0 && (width !== this.miniW || height !== this.miniH)) {
        this.miniW = width;
        this.miniH = height;
        Log.i(TAG, `mini video size ${width}x${height}`);
      }
    });
    player.on('error', (err: BusinessError) => {
      Log.e(TAG, `mini player error ${err.code} ${err.message} state=${player.state}`);
      /*
       * ⚠️ error 事件 **不等于播放失败** —— 这正是「小窗提示播放错误 5400102，其实能播」的锅。
       * 用户日志（2026-10-12 14:15:47）把链条摆得很清楚：
       *   `JsSetAudioInterruptMode In` → `OnErrorCb 5400102 ...unsupport audio interrupt operation`
       *   → `state=idle` →（同一毫秒）`setMediaSource` → initialized → prepared → playing，全程正常。
       * 那条 5400102 是**应用自己在 idle 状态设 audioInterruptMode 招来的**（现已改为在 prepared 下设置，
       * 见 AudioFocusUtil.applyInterruptMode）。凡是状态机时序类的 error，一律只记日志，
       * 界面维持「加载中」——用户明确要求这里应该显示加载中，而不是播放错误。
       */
      if (PlayerErrorUtil.shouldIgnore(err.code, player.state)) {
        Log.w(TAG, `ignore transient mini error ${err.code} in state ${player.state}`);
        if (!this.miniPlaying) {
          this.miniLoading = true;
          this.miniStatus = '';
        }
        return;
      }
      this.miniPlaying = false;
      this.miniLoading = false;
      this.applyKeepScreenOn(false);
      this.miniStatus = `播放错误 ${err.code}`;
    });
    // 音频焦点：不挂这个，被别的应用抢走焦点后系统会静音这条流，但 state 还是 playing
    AudioFocusUtil.attach(player, (kind: number) => {
      this.onAudioFocus(kind);
    });
    this.miniPlayer = player;
    return player;
  }

  private onMiniState(state: media.AVPlayerState, player: media.AVPlayer): void {
    if (state === 'initialized') {
      /*
       * ⚠️ 「能播起来」就靠这一步。
       * setMediaSource 之后状态机会走到 initialized，这时才能设 surfaceId，
       * 设完必须紧跟 prepare()，否则播放器永远停在 initialized ——
       * 界面表现就是一直「正在解析播放地址…」、进度 00:00 / 00:00。
       * surfaceId 只能在 initialized 设（idle 时设会抛 5400102），所以不能写在 doStartMini 里。
       * 播放页 VideoPlayerPage.onPlayerState 也是同一套时序，两边要一起改。
       */
      if (!this.miniVisible) {
        return;
      }
      if (this.miniSurfaceId.length === 0) {
        this.miniLoading = false;
        this.miniStatus = '视频表面未就绪';
        Log.w(TAG, 'mini initialized but surfaceId empty');
        return;
      }
      player.surfaceId = this.miniSurfaceId;
      Log.i(TAG, `mini initialized -> surfaceId=${this.miniSurfaceId}, prepare`);
      try {
        player.prepare();
      } catch (e) {
        const err = e as BusinessError;
        this.miniLoading = false;
        this.miniStatus = `缓冲失败 ${err.code}`;
        Log.e(TAG, `mini prepare failed ${err.code} ${err.message}`);
      }
    } else if (state === 'prepared') {
      this.miniLoading = false;
      /*
       * 音频焦点模式（SHARE_MODE）只能在这里设。
       * 早期在 createAVPlayer 之后立刻设，那时还是 idle，原生会回一条 5400102
       * 「unsupport audio interrupt operation」，被 error 回调当成「播放错误」弹给小窗。
       */
      AudioFocusUtil.applyInterruptMode(player);
      // 缓冲阶段就上常亮：不然起播那几秒正好撞上灭屏计时，画面还没出就黑了
      this.applyKeepScreenOn(true);
      if (this.miniStartMs > 0) {
        /*
         * 续播：prepared 状态下先 seek，等 seekDone 再 play。
         * 反过来的话刚起播的缓冲会把 seek 冲掉，表现就是「永远从头播」——播放页踩过同样的坑。
         */
        const from: number = this.miniStartMs;
        this.miniStartMs = 0;
        this.miniSavedMs = from;
        this.miniLastSavedMs = from;
        this.miniPendingSeek = true;
        try {
          player.seek(from);
        } catch (e) {
          Log.w(TAG, `mini seek threw ${e}`);
          this.miniPendingSeek = false;
        }
        if (this.miniPendingSeek) {
          // 兜底：个别片源不回调 seekDone，超时就强行起播
          this.clearMiniSeekGuard();
          this.miniSeekGuard = setTimeout(() => {
            this.miniSeekGuard = -1;
            if (this.miniPendingSeek) {
              Log.w(TAG, 'mini seekDone timeout, play anyway');
              this.miniPendingSeek = false;
              this.doMiniPlay(player);
            }
          }, MINI_RESUME_GUARD_MS);
          return;
        }
      }
      this.doMiniPlay(player);
    } else if (state === 'playing') {
      this.miniPlaying = true;
      this.miniLoading = false;
      this.miniStatus = '';
      // 起播意图达成，清掉重试状态（`miniWantPlay` 是用户意图，继续保留）
      this.miniPlayInFlight = false;
      this.miniPlayRetry = 0;
      // 真的在播了：保持常亮（播放画面本身不会阻止系统按锁屏时间息屏）
      this.applyKeepScreenOn(true);
      this.scheduleMiniHide();
      this.reportCastState(true);
    } else if (state === 'paused') {
      this.miniPlaying = false;
      // 暂停了就不必占着常亮，把系统行为交还给用户
      this.applyKeepScreenOn(false);
      // 暂停时控制条常驻：不然刚按下暂停，控制条就躲了，想拖进度还得先点一下画面
      this.miniShowControls = true;
      this.clearMiniHideTimer();
      this.reportCastState(false);
    } else if (state === 'completed') {
      this.reportCastState(false);
      this.onMiniCompleted();
    }
  }

  /**
   * 小窗起播。和播放页 `pumpPlay()` 一套思路：
   *   `play()` 只在 prepared / paused / completed 下允许，别的状态会抛
   *   `5400102 Operation not allowed` —— 起播瞬间状态还在跳，直接下发就会「起播失败 5400102」。
   * 所以：只登记意图 + 状态不合法就等（onMiniState 会再催），
   *       被拒就隔一小会儿重试一次，全都失败才写错误文案。
   */
  private doMiniPlay(player: media.AVPlayer): void {
    this.miniWantPlay = true;
    const st: media.AVPlayerState = player.state;
    if (st !== 'prepared' && st !== 'paused' && st !== 'completed') {
      Log.w(TAG, `mini play deferred, state=${st}`);
      return;
    }
    if (this.miniPlayInFlight) {
      return;
    }
    this.miniPlayInFlight = true;
    player.play().then(() => {
      this.miniPlayInFlight = false;
      this.miniPlayRetry = 0;
      Log.i(TAG, 'mini play started');
    }).catch((e: BusinessError) => {
      this.miniPlayInFlight = false;
      Log.e(TAG, `mini play failed ${e.code} ${e.message} state=${player.state}`);
      if (this.miniPlayRetry < PLAY_RETRY_MAX) {
        this.miniPlayRetry = this.miniPlayRetry + 1;
        const attempt: number = this.miniPlayRetry;
        setTimeout(() => {
          Log.i(TAG, `mini retry play (${attempt}/${PLAY_RETRY_MAX})`);
          this.doMiniPlay(player);
        }, PLAY_RETRY_DELAY_MS);
        return;
      }
      this.miniWantPlay = false;
      this.miniStatus = `起播失败 ${e.code}`;
    });
  }

  private clearMiniSeekGuard(): void {
    if (this.miniSeekGuard !== -1) {
      clearTimeout(this.miniSeekGuard);
      this.miniSeekGuard = -1;
    }
  }

  /** 一集播完：先落盘标记「已看完」，再按设置自动进下一集 */
  private onMiniCompleted(): void {
    this.miniReachedEnd = true;
    this.miniPlaying = false;
    this.miniWantPlay = false;
    // 播完了就松掉常亮（自动下一集时会在 prepared 里再打开）
    this.applyKeepScreenOn(false);
    this.saveMiniProgress();
    const eps: EpisodeModel[] = this.currentSourceEps();
    if (this.autoNext && this.miniEpIndex + 1 < eps.length) {
      Log.i(TAG, `mini auto next -> ${this.miniEpIndex + 1}`);
      this.playAt(this.miniSrcIndex, this.miniEpIndex + 1, false);
      return;
    }
    // 播完了就把控制条留在那儿，方便直接拖回去重看或按播放重头来
    this.miniShowControls = true;
    this.clearMiniHideTimer();
  }

  /* ---------- 全屏新增：倍速 / 音量 / 锁屏 / 画面比例 / 分享 / 片头尾 ---------- */

  /** 长按画面 → 临时 2x 快进，松手还原 */
  private startMiniLongPressSpeed(): void {
    const player: media.AVPlayer | undefined = this.miniPlayer;
    if (player === undefined) {
      return;
    }
    this.miniSpeedBeforeLongPress = this.miniSpeed;
    this.changeMiniSpeed(2.0);
    this.miniShowControls = false;
    this.clearMiniHideTimer();
  }

  private endMiniLongPressSpeed(): void {
    if (this.miniPlayer === undefined) {
      return;
    }
    this.changeMiniSpeed(this.miniSpeedBeforeLongPress);
  }

  private changeMiniSpeed(v: number): void {
    this.miniSpeed = v;
    const player: media.AVPlayer | undefined = this.miniPlayer;
    if (player === undefined) {
      return;
    }
    try {
      player.setPlaybackRate(v);
      Log.i(TAG, `mini playbackRate=${v}`);
    } catch (e) {
      Log.w(TAG, `mini setPlaybackRate failed: ${e}`);
      ToastUtil.show(this.getUIContext(), '当前视频不支持该倍速');
    }
  }

  /**
   * 音量手势：改的是**系统媒体音量**，不是播放器音量。
   * `AVPlayer.setVolume` 只调音频流的相对音量（基准是系统音量），系统音量条不会动，
   * 用户感觉不到"音量被调了"。这里把手势的 0~1 换算成系统音量等级交给根节点常驻的
   * `VolumePanelHost`，那才是真改系统音量（三方应用唯一官方途径，详见 VolumeUtil 注释）。
   */
  private applyMiniVolume(v: number): void {
    const level: number = VolumeUtil.levelOf(v);
    if (level === VolumeUtil.VOLUME_UNKNOWN) {
      return;
    }
    /* 档位没变就不下发（原因同 VideoPlayerPage.applyVolume：避免反复驱动系统音量 UIExtension） */
    if (level === this.miniVolumeLevel) {
      return;
    }
    VolumeUtil.noteLevel(level);
    this.miniVolumeLevel = level;
  }

  /** 切换「播完自动下一集」，并写回设置页（和横屏播放页一致） */
  private toggleAutoNext(): void {
    this.autoNext = !this.autoNext;
    AppSettings.current().autoNext = this.autoNext;
    AppSettings.save().catch((e: Error) => {
      Log.w(TAG, `saveAutoNext failed: ${e}`);
    });
    Log.i(TAG, `autoNext=${this.autoNext}`);
  }

  private toggleMiniLock(): void {    this.miniLocked = !this.miniLocked;
    this.miniShowControls = true;
    if (this.miniLocked) {
      this.clearMiniHideTimer();
    } else {
      this.scheduleMiniHide();
    }
    Log.i(TAG, `mini lock=${this.miniLocked}`);
  }

  private async shareMini(): Promise<void> {
    const ep: string = this.miniEpName.length > 0 ? ` ${this.miniEpName}` : '';
    const text: string = `我在影视仓看《${this.vod.name}》${ep}，一起看？`;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const ok: boolean = await ShareUtil.shareText(ctx, this.vod.name, text);
      if (!ok) {
        ToastUtil.show(this.getUIContext(), '分享面板打开失败');
      }
    } catch (e) {
      Log.w(TAG, `mini share failed: ${e}`);
      ToastUtil.show(this.getUIContext(), '分享失败');
    }
  }

  private markMiniIntro(): void {
    this.introMark.introEndSec = this.miniPosSec;
    this.hasIntroMark = true;
    IntroMarkStore.save(this.vod.name, this.introMark).catch((e: Error) => {
      Log.w(TAG, `mini save intro failed: ${e}`);
    });
    this.refreshMiniSkip();
    ToastUtil.show(this.getUIContext(), `片头结束点：${UrlUtil.formatTime(this.miniPosSec)}`);
  }

  private markMiniOutro(): void {
    this.introMark.outroStartSec = this.miniPosSec;
    this.hasOutroMark = true;
    IntroMarkStore.save(this.vod.name, this.introMark).catch((e: Error) => {
      Log.w(TAG, `mini save outro failed: ${e}`);
    });
    this.refreshMiniSkip();
    ToastUtil.show(this.getUIContext(), `片尾开始点：${UrlUtil.formatTime(this.miniPosSec)}`);
  }

  /** 按当前播放位置决定「跳过片头 / 跳过片尾」按钮是否出现 */
  private refreshMiniSkip(): void {
    let intro: string = '';
    if (this.introMark.introEndSec > 0 && this.miniPosSec > 0
      && this.miniPosSec < this.introMark.introEndSec) {
      intro = UrlUtil.formatTime(this.introMark.introEndSec);
    }
    let outro: string = '';
    if (this.hasOutroMark && this.introMark.outroStartSec > 0
      && this.miniPosSec >= this.introMark.outroStartSec) {
      outro = '下一集';
    }
    if (intro !== this.skipIntroText) {
      this.skipIntroText = intro;
    }
    if (outro !== this.skipOutroText) {
      this.skipOutroText = outro;
    }
  }

  /**
   * 片头 / 片尾标记的**自动生效**（和播放页 applyMarks 同一套语义）。
   *
   * 用户标「片头结束点」= 以后每次看都从这儿开始；标「片尾起始点」= 到这儿就进下一集。
   * 之前只弹一个需要手点的胶囊，用户反馈「已经选了跳过片头，影片还是从 0 播」。
   * 放在 timeUpdate 里执行：那时播放器在播，`seek()` 一定合法。
   */
  private applyMiniMarks(): void {
    if (!this.miniIntroAutoSkipped && this.introMark.introEndSec > 0
      && this.miniPosSec < this.introMark.introEndSec) {
      this.miniIntroAutoSkipped = true;
      const to: number = this.introMark.introEndSec;
      const player: media.AVPlayer | undefined = this.miniPlayer;
      Log.i(TAG, `mini auto skip intro ${this.miniPosSec}s -> ${to}s`);
      if (player !== undefined) {
        try {
          player.seek(to * 1000);
        } catch (e) {
          Log.w(TAG, `mini auto skip intro seek failed: ${e}`);
        }
        ToastUtil.show(this.getUIContext(), `已跳过片头 ${UrlUtil.formatTime(to)}`);
      }
      return;
    }
    if (!this.miniOutroAutoSkipped && this.hasOutroMark && this.introMark.outroStartSec > 0
      && this.miniPosSec >= this.introMark.outroStartSec) {
      const eps: EpisodeModel[] = this.currentSourceEps();
      if (!this.autoNext || this.miniEpIndex + 1 >= eps.length) {
        return;
      }
      this.miniOutroAutoSkipped = true;
      Log.i(TAG, `mini auto skip outro ${this.miniPosSec}s -> ep ${this.miniEpIndex + 1}`);
      ToastUtil.show(this.getUIContext(), '已跳过片尾，播放下一集');
      this.playAt(this.miniSrcIndex, this.miniEpIndex + 1, false);
    }
  }

  /** 读这部片的片头/片尾标记（按片名，片名要等 load() 拿到 vod 之后才有） */
  private loadIntroMark(): void {
    if (this.vod.name.length === 0) {
      return;
    }
    IntroMarkStore.load(this.vod.name).then((m: IntroMark) => {
      this.introMark = m;
      this.hasIntroMark = m.introEndSec > 0;
      this.hasOutroMark = m.outroStartSec > 0;
      this.refreshMiniSkip();
    }).catch((e: Error) => {
      Log.w(TAG, `loadIntroMark failed: ${e}`);
    });
  }

  /* ---------- 进度条拖动 ---------- */

  /** 滑块位置：拖动中跟手指走，否则跟播放进度走 */
  private miniSliderValue(): number {
    if (this.miniDragging && this.miniDurSec > 0) {
      return this.miniDragSec / this.miniDurSec * 100;
    }
    return this.miniPercent();
  }

  private onMiniSlider(value: number, mode: SliderChangeMode): void {
    if (mode === SliderChangeMode.Begin) {
      // 拖动期间别让 timeUpdate 把滑块拽回去
      this.miniDragging = true;
      // 以当前播放位置起拖：miniDragSec 还停在上一轮的值会让滑块先跳一下
      this.miniDragSec = this.miniPosSec;
      this.clearMiniHideTimer();
    }
    if (this.miniDurSec > 0) {
      this.miniDragSec = Math.floor(value / 100 * this.miniDurSec);
    }
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.miniDragging = false;
      this.seekMiniToSec(this.miniDragSec);
    }
  }

  private seekMiniToSec(sec: number): void {
    this.miniShowControls = true;
    this.scheduleMiniHide();
    const player: media.AVPlayer | undefined = this.miniPlayer;
    if (player === undefined || this.miniDurSec <= 0) {
      return;
    }
    const total: number = this.miniDurSec * 1000;
    let ms: number = sec * 1000;
    if (ms < 0) {
      ms = 0;
    }
    if (ms > total) {
      ms = total;
    }
    try {
      player.seek(ms);
      this.miniSavedMs = ms;
      this.miniLastSavedMs = ms;
      this.miniPosSec = Math.floor(ms / 1000);
      if (ms < total) {
        // 从「已播完」的位置往回拖，就该重新算作没看完
        this.miniReachedEnd = false;
      }
    } catch (e) {
      Log.w(TAG, `mini seek failed: ${e}`);
    }
  }

  private toggleMiniPlay(): void {
    const player: media.AVPlayer | undefined = this.miniPlayer;
    if (player === undefined) {
      // 还没起播：控制条上的播放键等同于点封面
      if (!this.miniVisible) {
        this.playAt(this.curSource, this.curEpisode, true);
      }
      return;
    }
    let toPause: boolean = false;
    try {
      if (player.state === 'playing') {
        player.pause();
        this.saveMiniProgress();
        toPause = true;
      } else if (player.state === 'paused' || player.state === 'prepared') {
        this.miniWantPlay = true;
        player.play();
      } else if (player.state === 'completed') {
        this.miniReachedEnd = false;
        this.miniWantPlay = true;
        player.seek(0);
        player.play();
      }
    } catch (e) {
      // pause()/play() 在状态不匹配时会**同步**抛，必须就地接住
      Log.w(TAG, `mini toggle failed: ${e}`);
    }
    this.miniShowControls = true;
    if (toPause) {
      // 用户主动暂停 —— 这是唯一会清掉「播放意图」的地方
      this.miniWantPlay = false;
      // 暂停态控制条不隐藏
      this.miniPlaying = false;
      this.clearMiniHideTimer();
    } else {
      this.scheduleMiniHide();
    }
  }

  /**
   * 放大：**就地**铺满横屏，不跳页。
   *
   * 之前这里是 pushUrl 到 VideoPlayerPage —— 那会新建一个 AVPlayer、
   * 重新拉一次 m3u8、重新缓冲，用户看到的就是「放大后从头加载一遍」。
   * 现在只是把同一个 XComponent 的容器撑满窗口 + 转横屏：
   * 播放器实例、已经缓冲的数据、播放位置全都不动，是真·无缝放大。
   */
  private expandMini(): void {
    if (this.miniFullscreen) {
      return;
    }
    this.miniFullscreen = true;
    // 进全屏默认不锁屏；控制层亮出来给一个明确的入口
    this.miniLocked = false;
    this.miniShowControls = true;
    this.scheduleMiniHide();
    this.applyLandscape(true);
    Log.i(TAG, `mini expand src=${this.miniSrcIndex} ep=${this.miniEpIndex} posSec=${this.miniPosSec}`);
  }

  /** 退出全屏：转回竖屏，其余一概不动（画面继续播，不重载） */
  private exitMiniFullscreen(): void {
    if (!this.miniFullscreen) {
      return;
    }
    this.miniFullscreen = false;
    // 全屏专属状态一并复位（画面、播放器一个都不动）
    this.miniLocked = false;
    this.miniShowControls = true;
    this.scheduleMiniHide();
    this.applyLandscape(false);
    Log.i(TAG, 'mini collapse');
  }

  /**
   * 切屏幕方向 + 系统栏显隐（和播放页同一套做法）。
   * 顺手把窗口宽高比捞回来 —— 全屏时容器要靠它撑满。
   */
  private async applyLandscape(land: boolean): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(land ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT);
      if (land) {
        await win.setWindowSystemBarEnable([]);
      } else {
        await win.setWindowSystemBarEnable(['status', 'navigation']);
      }
      this.syncScreenAspect(win);
      // 旋转是异步的：等尺寸真正翻过来再捞一次，不然容器会按旧比例铺一帧
      setTimeout(() => {
        this.syncScreenAspect(win);
      }, 420);
    } catch (e) {
      Log.w(TAG, `mini applyLandscape(${land}) failed: ${e}`);
    }
  }

  private syncScreenAspect(win: window.Window): void {
    try {
      const rect: window.Rect = win.getWindowProperties().windowRect;
      if (rect.width <= 0 || rect.height <= 0) {
        return;
      }
      const a: number = rect.width / rect.height;
      if (Math.abs(a - this.screenAspect) > 0.01) {
        this.screenAspect = a;
        Log.i(TAG, `screen aspect=${a.toFixed(3)}`);
      }
    } catch (e) {
      Log.w(TAG, `mini syncScreenAspect failed: ${e}`);
    }
  }

  /**
   * 播放中让屏幕别熄灭。
   * 不加这个，全屏横屏看着看着就到系统锁屏时间自动息屏了 —— 播放器的画面刷新并不影响
   * 系统的灭屏计时，必须显式 request。真正的「是否要下发」判断在 ScreenUtil 里。
   */
  private applyKeepScreenOn(on: boolean): void {
    ScreenUtil.setKeepScreenOn(this.getUIContext(), on, 'mini');
  }

  /**
   * 收起小窗：释放播放器并把状态清干净。
   * 目前没有入口调用（返回键直接销毁整个详情页），留给后续「收起小窗」按钮用。
   */
  private closeMini(): void {
    if (this.miniFullscreen) {
      this.miniFullscreen = false;
      this.applyLandscape(false);
    }
    this.clearMiniHideTimer();
    this.clearMiniSeekGuard();
    this.miniPendingSeek = false;
    this.releaseMiniPlayer();
    this.applyKeepScreenOn(false);
    this.miniVisible = false;
    this.miniSurfaceReady = false;
    this.miniSurfaceId = '';
    this.miniPlaying = false;
    this.miniLoading = false;
    this.miniStatus = '';
    this.miniUrl = '';
    this.miniHeaders = undefined;
    this.miniPosSec = 0;
    this.miniDurSec = 0;
  }

  /** 页面被盖住时只暂停，不释放（回来多半还要接着看） */
  private pauseMini(): void {
    const player: media.AVPlayer | undefined = this.miniPlayer;
    if (player === undefined || player.state !== 'playing') {
      return;
    }
    try {
      player.pause();
    } catch (e) {
      Log.w(TAG, `mini pause failed: ${e}`);
    }
    this.saveMiniProgress();
  }

  /** 立刻停掉当前播放（换集/换线路时先让它安静下来） */
  private stopMiniPlayback(): void {
    this.miniPlaying = false;
    this.miniWantPlay = false;
    this.enqueueMini(() => this.doStopMini());
  }

  private async doStopMini(): Promise<void> {
    const player: media.AVPlayer | undefined = this.miniPlayer;
    if (player === undefined || player.state === 'idle') {
      return;
    }
    try {
      await player.reset();
    } catch (e) {
      Log.w(TAG, `mini reset failed: ${e}`);
    }
  }

  private releaseMiniPlayer(): void {
    const player: media.AVPlayer | undefined = this.miniPlayer;
    // 先摘掉引用：排队中的起播任务发现 miniPlayer 已换/已空就不会再动它
    this.miniPlayer = undefined;
    if (player === undefined) {
      return;
    }
    this.enqueueMini(() => {
      return player.release().then(() => {
        Log.i(TAG, 'mini player released');
      }).catch((e: BusinessError) => {
        Log.w(TAG, `mini release failed ${e.code}`);
      });
    });
  }

  /**
   * 小窗的进度也要写进历史 —— 否则在小窗里看了半小时，历史里还是 0。
   * 走 mergeHistory（和播放页同一套「已看集位图 + 合并写入」），两边不会互相覆盖。
   */
  private saveMiniProgress(): void {
    if (this.vod.id.length === 0) {
      return;
    }
    const eps: EpisodeModel[] = this.currentSourceEps();
    const durMs: number = this.miniDurSec > 0 ? this.miniDurSec * 1000 : 0;
    const posMs: number = this.miniSavedMs > 0 ? Math.floor(this.miniSavedMs) : 0;
    const finished: boolean = this.miniReachedEnd
      || (durMs > 0 && posMs > 0 && posMs >= durMs - MINI_END_MARGIN_MS);

    const rec: PlayRecord = new PlayRecord();
    rec.siteKey = this.vod.siteKey;
    rec.vodId = this.vod.id;
    rec.vodName = this.vod.name;
    rec.pic = this.vod.pic;
    rec.sourceIndex = this.miniSrcIndex;
    rec.sourceName = this.sourceNameOf(this.miniSrcIndex);
    rec.episodeIndex = this.miniEpIndex;
    rec.episodeName = this.epNameOf(this.miniSrcIndex, this.miniEpIndex);
    rec.positionMs = posMs;
    rec.durationMs = durMs;
    rec.finished = finished;
    rec.totalEpisodes = eps.length;
    rec.watchedMask = this.watchedMask;
    if (finished) {
      rec.markWatched(this.miniEpIndex);
      // 内存镜像同步：集列表打标、后续 merge 都依赖它
      this.watchedMask = rec.watchedMask;
    }
    rec.updatedAt = Date.now();
    PlayDataStore.mergeHistory(rec).then(() => {
      // doMerge 会把旧位图并回来，这里重算一次聚合进度，顶部的进度条跟着爬
      this.watchCount = rec.watchedCount();
      this.watchRatio = rec.watchedRatio();
    }).catch((e: Error) => {
      Log.w(TAG, `mini saveProgress failed: ${e}`);
    });
  }

  /** 小窗控制条的自动隐藏 */
  private scheduleMiniHide(): void {
    this.clearMiniHideTimer();
    const delay: number = this.miniFullscreen ? MINI_HIDE_DELAY_FS_MS : MINI_HIDE_DELAY_MS;
    this.miniHideTimer = setTimeout(() => {
      this.miniHideTimer = -1;
      // 解析中 / 有错误提示时别把提示藏起来
      if (this.miniLoading || this.miniStatus.length > 0) {
        return;
      }
      this.miniShowControls = false;
    }, delay);
  }

  private clearMiniHideTimer(): void {
    if (this.miniHideTimer !== -1) {
      clearTimeout(this.miniHideTimer);
      this.miniHideTimer = -1;
    }
  }

  /**
   * 点画面唤出控制条（竖屏小窗用）。
   * 全屏走 PlayerGestureLayer，单击是双向切换（显示↔隐藏），由 toggleMiniControls 处理；
   * 这里保持「只显不收」的旧行为：控制条上的按钮点击会冒泡到这里，
   * 若做成双向切换，点一下暂停就会把控制条一起收掉 —— 竖屏下很难用。
   */
  private toggleMiniControls(): void {
    // 锁屏时单击不改变状态：解锁按钮必须一直留着
    if (this.miniLocked) {
      return;
    }
    if (this.miniFullscreen) {
      // 全屏：单击就是双向切换（和各家手机播放器一致）
      this.miniShowControls = !this.miniShowControls;
      if (this.miniShowControls) {
        this.scheduleMiniHide();
      } else {
        this.clearMiniHideTimer();
      }
      return;
    }
    if (!this.miniShowControls) {
      this.miniShowControls = true;
    }
    this.scheduleMiniHide();
  }

  /* ---------- 小窗尺寸与文案 ---------- */

  private miniRatio(): number {
    // 16:9 / 4:3 是强制比例（老片 / 宽银幕手动切换），其余用片源真实比例
    if (this.miniAspect === ASPECT_16_9) {
      return 16 / 9;
    }
    if (this.miniAspect === ASPECT_4_3) {
      return 4 / 3;
    }
    if (this.miniW > 0 && this.miniH > 0) {
      return this.miniW / this.miniH;
    }
    return 16 / 9;
  }

  /** 小窗容器的高宽比：按真实比例，但夹在 [3/4, 21/9] 之间，避免极端比例的片子霸占整屏 */
  private miniBoxRatio(): number {
    // 全屏：容器要正好铺满窗口，直接用窗口自己的宽高比。
    // 旋转是异步的，sample 还没翻过来时这里拿到的可能还是竖屏比例（<1），
    // 那种值撑起来会溢出屏幕，不如先用 16:9 顶一帧。
    if (this.miniFullscreen) {
      return this.screenAspect > 1 ? this.screenAspect : 16 / 9;
    }
    const r: number = this.miniRatio();
    if (r < 0.75) {
      return 0.75;
    }
    // 上限从 2.34 收到 2.0：宽银幕（2.35:1）片源在竖屏下会把窗口压成很扁的一条，
    // 收到 2:1 让容器高一点、更像一个播放窗，画面本身仍是等比居中，不会变形
    if (r > 2.0) {
      return 2.0;
    }
    return r;
  }

  /** 画面在小窗里等比铺满后的宽度（vp）；容器尺寸还没测出来时先铺满，拿到比例后立刻纠正 */
  private miniRenderW(): Length {
    if (this.miniBoxW <= 0 || this.miniBoxH <= 0) {
      return '100%';
    }
    const r: number = this.miniRatio();
    const box: number = this.miniBoxW / this.miniBoxH;
    if (this.miniAspect === ASPECT_FILL) {
      // 铺满：短边顶满，长边溢出后被容器的 clip 裁掉（真裁边，不是拉伸）
      return r >= box ? this.miniBoxH * r : this.miniBoxW;
    }
    return r >= box ? this.miniBoxW : this.miniBoxH * r;
  }

  private miniRenderH(): Length {
    if (this.miniBoxW <= 0 || this.miniBoxH <= 0) {
      return '100%';
    }
    const r: number = this.miniRatio();
    const box: number = this.miniBoxW / this.miniBoxH;
    if (this.miniAspect === ASPECT_FILL) {
      return r >= box ? this.miniBoxH : this.miniBoxW / r;
    }
    return r >= box ? this.miniBoxW / r : this.miniBoxH;
  }

  private miniPercent(): number {
    if (this.miniDurSec <= 0) {
      return 0;
    }
    let p: number = this.miniPosSec / this.miniDurSec * 100;
    if (p > 100) {
      p = 100;
    }
    if (p < 0) {
      p = 0;
    }
    return p;
  }

  private epNameOf(srcIndex: number, epIndex: number): string {
    if (srcIndex < 0 || srcIndex >= this.sources.length) {
      return '';
    }
    const eps: EpisodeModel[] = this.sources[srcIndex].episodes;
    if (epIndex < 0 || epIndex >= eps.length) {
      return '';
    }
    return eps[epIndex].name;
  }

  private sourceNameOf(srcIndex: number): string {
    if (srcIndex < 0 || srcIndex >= this.sources.length) {
      return '';
    }
    return this.sources[srcIndex].name;
  }

  private currentSourceEps(): EpisodeModel[] {
    if (this.miniSrcIndex >= 0 && this.miniSrcIndex < this.sources.length) {
      return this.sources[this.miniSrcIndex].episodes;
    }
    return [];
  }

  /** 站点找不到时给解析器一个占位站点（ParseResolver 要求 site 必填） */
  private siteOf(): SiteModel {
    const s: SiteModel | undefined = this.findSite(this.vod.siteKey);
    return s === undefined ? FallbackSite.value : s;
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.errMsg = '';
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await ConfigManager.get().ensureInit(ctx);
    } catch (e) {
      Log.w(TAG, `ensureInit failed: ${e}`);
    }
    // 小窗的连播行为跟随设置页，和播放页保持一致
    try {
      const s: AppSettingsData = await AppSettings.ensure();
      this.autoNext = s.autoNext;
    } catch (e) {
      Log.w(TAG, `load settings failed: ${e}`);
    }

    // 列表页通常只有基础字段，需要一次详情请求补全播放地址
    if (this.vod.playUrl.length === 0) {
      const site: SiteModel | undefined = this.findSite(this.vod.siteKey);
      if (site === undefined) {
        this.errMsg = `找不到站点 ${this.vod.siteKey}，可能配置源已更换`;
        this.loading = false;
        return;
      }
      const full: VodItem | undefined = await SiteRouter.detail(site, this.vod.id);
      if (full === undefined) {
        this.errMsg = '详情请求失败，接口可能已失效';
        this.loading = false;
        return;
      }
      if (full.pic.length === 0) {
        full.pic = this.vod.pic;
      }
      if (full.name.length === 0) {
        full.name = this.vod.name;
      }
      if (full.content.length === 0) {
        full.content = this.vod.content;
      }
      this.vod = full;
    }

    this.sources = PlayUrlParser.sortByPlayability(
      PlayUrlParser.parse(this.vod.playFrom, this.vod.playUrl));
    this.loading = false;

    // 片头/片尾标记按片名读（这时 vod.name 才确定）
    this.loadIntroMark();

    if (this.sources.length === 0) {
      this.errMsg = '未从接口拿到 vod_play_url，可能是解析型片源(需 Spider)';
      this.rows = [];
      this.epDs.setItems(this.rows);
      return;
    }

    // 续播位置
    await this.refreshResume();

    this.favored = await PlayDataStore.isFavorite(this.vod.siteKey, this.vod.id);
    this.rebuildEpisodes();
    Log.i(TAG, `${this.vod.name} sources=${this.sources.length}`);

    // 进详情页直接起播（用户定稿：不要「点了才播」）。
    // 放在 refreshResume 之后，curSource / curEpisode 才是续播对齐过的线路与集号，
    // allowResume=true 才能把「上次看到 12:34」接上。
    this.autoStartPreview();
  }

  /**
   * 进页面自动起播小窗。
   * 只在 load() 末尾触发，**不放进 onPageShow**：从播放页返回时小窗本来就挂着，
   * 再来一次会打断它当前的播放位置。重进页面的样子由 resumeMiniIfPaused() 负责。
   */
  private autoStartPreview(): void {
    if (this.miniVisible || this.sources.length === 0) {
      return;
    }
    Log.i(TAG, `auto play on enter: src=${this.curSource} ep=${this.curEpisode}`);
    this.playAt(this.curSource, this.curEpisode, true);
  }

  /** 从播放页 / 后台回到详情页：小窗还挂着且是暂停态，就接着放 */
  private resumeMiniIfPaused(): void {
    const player: media.AVPlayer | undefined = this.miniPlayer;
    if (!this.miniVisible || player === undefined || !this.miniWantPlay) {
      return;
    }
    if (player.state === 'paused' || player.state === 'prepared') {
      // 走 doMiniPlay 而不是直接 play()：它会先校验状态并吃掉 5400102 这类瞬时拒绝
      this.doMiniPlay(player);
    }
  }

  /**
   * 读取播放历史，解出「续播到哪一集、哪个位置」并落到 state 上。
   *
   * 两个对齐动作，缺一个都会续错：
   *  1. 线路：PlayUrlParser.sortByPlayability 会重排线路，历史里的 sourceIndex 可能已经指到别的线路 → 用 sourceName 对齐。
   *  2. 集号：换站后 vodId 变了，各站集顺序也不一致 → 用 episodeName 在当前线路的剧集表里找回下标。
   */
  private async refreshResume(): Promise<void> {
    this.resumeMs = 0;
    this.resumeSrc = -1;
    this.resumeEp = -1;
    this.resumeKind = 0;
    this.watchRatio = 0;
    this.watchCount = 0;
    this.watchedMask = '';
    if (this.sources.length === 0 || this.vod.id.length === 0) {
      this.resumeText = '';
      return;
    }
    let rec: PlayRecord | undefined = undefined;
    try {
      rec = await PlayDataStore.findResume(this.vod.name, this.vod.siteKey, this.vod.id);
    } catch (e) {
      Log.w(TAG, `findResume failed: ${e}`);
      return;
    }
    if (rec === undefined || rec.episodeName.length === 0) {
      this.resumeText = '';
      return;
    }

    const sameVod: boolean = rec.siteKey === this.vod.siteKey && rec.vodId === this.vod.id;
    const srcIdx: number = this.matchSourceIndex(rec);
    const eps: EpisodeModel[] = this.sources[srcIdx].episodes;

    let epIdx: number = rec.episodeIndex >= 0 ? rec.episodeIndex : 0;
    if (!sameVod) {
      const byName: number = VideoDetailPage.indexOfEpisode(eps, rec.episodeName);
      epIdx = byName >= 0 ? byName : 0;
    }
    if (epIdx >= eps.length) {
      epIdx = 0;
    }

    this.watchedMask = rec.watchedMask;
    this.watchCount = rec.watchedCount();
    this.watchRatio = rec.watchedRatio();
    this.curSource = srcIdx;
    this.resumeSrc = srcIdx;
    const agg: string = rec.episodeProgressText();

    if (rec.finished && epIdx + 1 < eps.length) {
      // 本集已看完 → 续播点顺延到下一集、从头播（多集连播的关键一步）
      const next: number = epIdx + 1;
      this.curEpisode = next;
      this.resumeEp = next;
      this.resumeMs = 0;
      this.resumeKind = 2;
      const head: string = `已看完 ${rec.episodeName}`;
      const tail: string = `接着看 ${eps[next].name}`;
      this.resumeText = agg.length > 0 ? `${head} · ${agg} · ${tail}` : `${head} · ${tail}`;
    } else if (rec.finished) {
      // 最后一集也看完了：停在原地，主按钮退化成「重新播放」
      this.curEpisode = epIdx;
      this.resumeEp = epIdx;
      this.resumeMs = 0;
      this.resumeKind = 3;
      this.resumeText = agg.length > 0 ? `${agg} · 已全部看完` : '已全部看完';
    } else {
      this.curEpisode = epIdx;
      this.resumeEp = epIdx;
      this.resumeMs = PlayRecord.resumeTargetMs(rec);
      this.resumeKind = this.resumeMs > 0 ? 1 : 0;
      const head: string = `上次看到 ${rec.episodeName}`;
      const tail: string = PlayRecord.progressText(rec);
      this.resumeText = agg.length > 0 ? `${head} · ${agg} · ${tail}` : `${head} · ${tail}`;
    }
    this.rebuildEpisodes();
  }

  /** 在剧集表里按名字找下标（各站集名基本一致，用来跨站对齐） */
  private static indexOfEpisode(eps: EpisodeModel[], name: string): number {
    for (let i = 0; i < eps.length; i++) {
      if (eps[i].name === name) {
        return i;
      }
    }
    return -1;
  }

  /** 历史记录里的线路 → 当前 sources 下标 */
  private matchSourceIndex(rec: PlayRecord): number {
    if (rec.sourceName.length > 0) {
      for (let i = 0; i < this.sources.length; i++) {
        if (this.sources[i].name === rec.sourceName) {
          return i;
        }
      }
    }
    return (rec.sourceIndex >= 0 && rec.sourceIndex < this.sources.length) ? rec.sourceIndex : 0;
  }

  private findSite(key: string): SiteModel | undefined {
    const cfg = ConfigManager.get();
    for (let i = 0; i < cfg.sites.length; i++) {
      if (cfg.sites[i].key === key) {
        return cfg.sites[i];
      }
    }
    for (let i = 0; i < cfg.allSites.length; i++) {
      if (cfg.allSites[i].key === key) {
        if (cfg.isUsable(cfg.allSites[i])) {
          return cfg.allSites[i];
        }
      }
    }
    return undefined;
  }

  private rebuildEpisodes(): void {
    if (this.curSource < 0 || this.curSource >= this.sources.length) {
      this.rows = [];
      this.epDs.setItems(this.rows);
      return;
    }
    this.rows = EpisodeRow.chunk(
      this.sources[this.curSource].episodes,
      this.epCols,
      `ds_${this.curSource}_${this.epCols}`);
    this.epDs.setItems(this.rows);
  }

  private switchSource(idx: number): void {
    if (idx === this.curSource) {
      return;
    }
    this.curSource = idx;
    this.curEpisode = 0;
    this.rebuildEpisodes();
    // 小窗开着就直接在新线路上接着播：否则画面还停在旧线路，和上面高亮的线路对不上
    if (this.miniVisible) {
      this.openMini(idx, 0, this.miniSavedMs > 0 ? Math.floor(this.miniSavedMs) : 0);
    }
  }

  /**
   * 点「立即播放」/选集。
   *
   * 现在的行为是**不跳页**：直接在本页顶部弹出内嵌播放小窗开始播，
   * 想看大屏再点小窗上的「放大」（走 expandMini → 横屏播放页）。
   *
   * @param allowResume 允许续播：只有「点的是历史记录里那一集」才带进度起播，
   *                    用户主动点别的集必须从头播。
   */
  private playAt(sourceIndex: number, episodeIndex: number, allowResume: boolean): void {
    if (sourceIndex < 0 || sourceIndex >= this.sources.length) {
      return;
    }
    const eps: EpisodeModel[] = this.sources[sourceIndex].episodes;
    if (eps.length === 0) {
      return;
    }
    const ep: number = episodeIndex >= 0 && episodeIndex < eps.length ? episodeIndex : 0;

    let startMs: number = 0;
    if (allowResume && this.resumeMs > 0 && this.resumeSrc === sourceIndex && this.resumeEp === ep) {
      startMs = this.resumeMs;
    }

    // 当前集跟着走：线路/选集的高亮、以及「选集 · 线路 N 集」都要准
    this.curSource = sourceIndex;
    this.curEpisode = ep;
    this.rebuildEpisodes();
    Log.i(TAG, `mini play src=${this.sources[sourceIndex].name} ep=${ep} startMs=${startMs}`);
    this.openMini(sourceIndex, ep, startMs);
  }

  private async toggleFavorite(): Promise<void> {
    this.favored = await PlayDataStore.toggleFavorite(this.vod);
  }

  /* ==================== 选集面板 / 下载 ==================== */

  /**
   * 拉出选集面板（右侧滑出，和播放页同一套 `EpisodeDialog`）。
   * 详情页**全屏时也能用** —— 以前这里只能「退出全屏回竖屏再选」，多一步很别扭。
   */
  private openEpisodeDialog(): void {
    if (this.sources.length === 0) {
      ToastUtil.show(this.getUIContext(), '还没有拿到剧集列表');
      return;
    }
    this.buildEpisodeDialog();
    this.epCtrl?.open();
    this.miniShowControls = true;
    this.clearMiniHideTimer();
  }

  private buildEpisodeDialog(): void {
    const ctrl: CustomDialogController = new CustomDialogController({
      builder: EpisodeDialog({
        sources: this.sources,
        currentSource: this.miniSrcIndex,
        currentEpisode: this.miniEpIndex,
        watchedMask: this.watchedMask,
        onPick: (s: number, e: number) => {
          this.playAt(s, e, false);
        },
        onClose: () => {
          this.epCtrl?.close();
        }
      }),
      autoCancel: true,
      // 贴右边缘、占满高度（详见 EpisodeDialog 头部说明）
      alignment: DialogAlignment.CenterEnd,
      maskColor: 'rgba(0,0,0,0.35)',
      customStyle: true
    });
    this.epCtrl = ctrl;
  }

  /** 打开下载面板：选「全部剧集」或逐集多选 */
  private openDownloadDialog(): void {
    if (this.currentSourceEps().length === 0) {
      ToastUtil.show(this.getUIContext(), '还没有拿到剧集列表');
      return;
    }
    this.buildDownloadDialog();
    this.downloadCtrl?.open();
  }

  private buildDownloadDialog(): void {
    const ctrl: CustomDialogController = new CustomDialogController({
      builder: DownloadDialog({
        episodes: this.currentSourceEps(),
        currentEpisode: this.miniEpIndex,
        onConfirm: (all: boolean, indices: number[]) => {
          this.startDownload(all, indices);
        },
        onClose: () => {
          this.downloadCtrl?.close();
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true
    });
    this.downloadCtrl = ctrl;
  }

  /**
   * 真正开下：**逐集串行** —— 先解析直链（ParseResolver），再交给系统下载服务排队。
   * 串行是故意的：几十集一起并发解析会被采集站当攻击，轻则限流重则封 IP。
   */
  private async startDownload(all: boolean, indices: number[]): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    const eps: EpisodeModel[] = this.currentSourceEps();
    const list: number[] = all ? VideoDetailPage.allIndices(eps.length) : indices;
    if (list.length === 0) {
      return;
    }
    if (list.length > DownloadUtil.maxBatch()) {
      ToastUtil.show(this.getUIContext(), `一次最多下载 ${DownloadUtil.maxBatch()} 集`);
      return;
    }
    DownloadUtil.reset();
    this.downloadText = `准备中 0/${list.length}`;
    ToastUtil.show(this.getUIContext(), `开始下载 ${list.length} 集，下完可在「我的 → 我的下载」里播放`);
    let queued: number = 0;
    for (let i = 0; i < list.length; i++) {
      const idx: number = list[i];
      if (idx < 0 || idx >= eps.length) {
        continue;
      }
      const ep: EpisodeModel = eps[idx];
      this.downloadText = `准备中 ${i}/${list.length}`;
      let pr: ParseResult = new ParseResult();
      try {
        pr = await ParseResolver.resolve(ep.url, this.siteOf(), ConfigManager.get().parses, -1);
      } catch (e) {
        pr.ok = false;
        pr.error = `${e}`;
      }
      if (!pr.ok || pr.url.length === 0) {
        Log.w(TAG, `download skip ${ep.name}: ${pr.error}`);
        continue;
      }
      const name: string = DownloadUtil.fileNameOf(this.vod.name, ep.name, pr.url);
      const started: boolean = await DownloadUtil.enqueue(ctx, pr.url, pr.headers, name);
      if (started) {
        queued = queued + 1;
      }
    }
    Log.i(TAG, `download queued ${queued}/${list.length}`);
    if (queued === 0) {
      // 一集都没排上（全解析失败）：把胶囊清掉，免得一直挂在那
      this.downloadText = '';
      ToastUtil.show(this.getUIContext(), '这些集都没解析出可下载的地址');
    }
  }

  private static allIndices(n: number): number[] {
    const out: number[] = [];
    for (let i = 0; i < n; i++) {
      out.push(i);
    }
    return out;
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
    const cols: number = inner < 380 ? 4 : (inner < 700 ? 5 : 7);
    if (cols !== this.epCols) {
      this.epCols = cols;
      this.rebuildEpisodes();
    }
  }

  private totalEpisodes(): number {
    if (this.curSource >= 0 && this.curSource < this.sources.length) {
      return this.sources[this.curSource].episodes.length;
    }
    return 0;
  }

  private currentSourceName(): string {
    if (this.curSource >= 0 && this.curSource < this.sources.length) {
      return this.sources[this.curSource].name;
    }
    return '';
  }

  private isCurrentEpisode(index: number): boolean {
    return index === this.curEpisode;
  }

  /** 该集是否已看完（当前集不标灰 —— 当前集优先高亮） */
  private isWatchedEp(index: number): boolean {
    if (index === this.curEpisode) {
      return false;
    }
    return PlayRecord.isWatchedAt(this.watchedMask, index);
  }

  private epTextColor(index: number): string {
    if (index === this.curEpisode) {
      return '#FFFFFF';
    }
    return this.isWatchedEp(index) ? AppTheme.EP_DONE_TEXT : AppTheme.TEXT_PRIMARY;
  }

  private epBgColor(index: number): string {
    if (index === this.curEpisode) {
      return AppTheme.ACCENT;
    }
    return this.isWatchedEp(index) ? AppTheme.EP_DONE_BG : AppTheme.CARD;
  }

  /** 聚合进度文案：已看 3/24 集 · 12% */
  private progressSummary(): string {
    const total: number = this.totalEpisodes();
    const pct: number = Math.round(this.watchRatio * 100);
    if (total > 0) {
      return `已看 ${this.watchCount}/${total} 集 · ${pct}%`;
    }
    return `已看 ${this.watchCount} 集 · ${pct}%`;
  }

  /**
   * 主按钮文案：
   * 本集有进度 → 继续观看；本集看完还有下一集 → 接着看下一集；全部看完 → 重新播放。
   */
  private playButtonText(): string {
    if (this.resumeKind === 1) {
      return '继续观看';
    }
    if (this.resumeKind === 2) {
      return '接着看下一集';
    }
    if (this.resumeKind === 3) {
      return '重新播放';
    }
    return '立即播放';
  }

  private metaLine(): string {
    const parts: string[] = [];
    if (this.vod.year.length > 0) {
      parts.push(this.vod.year);
    }
    if (this.vod.area.length > 0) {
      parts.push(this.vod.area);
    }
    if (this.vod.typeName.length > 0) {
      parts.push(this.vod.typeName);
    }
    if (this.vod.director.length > 0) {
      parts.push(`导演 ${this.vod.director}`);
    }
    if (parts.length === 0) {
      return `ID ${this.vod.id}`;
    }
    return parts.join(' · ');
  }

  private fillers(count: number): number[] {
    const out: number[] = [];
    for (let i = count; i < this.epCols; i++) {
      out.push(i);
    }
    return out;
  }

  private safeBottomPx(): number {
    const v: number | undefined = AppStorage.get<number>('safeBottomPx');
    return v === undefined ? 0 : v;
  }
}

/**
 * 站点找不到时给解析器一个占位站点（ParseResolver 要求 site 必填）。
 * 小窗和播放页都用这一套：拿不到站点也得能直连播出地址。
 */
class FallbackSite {
  static readonly value: SiteModel = {
    key: '__none__',
    name: '未知来源',
    type: 1,
    api: ''
  };
}
