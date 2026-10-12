import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  EpisodeModel, PlaySourceModel, SiteModel, VodItem
} from '../../../commons/models/TvBoxModels';
import { PlayerParams, SnifferParams } from '../../../commons/models/RouteParams';
import { PlayRecord } from '../../../commons/models/PlayRecordModel';
import { TrackOption } from '../../../commons/models/TrackModel';
import { ConfigManager } from '../../source/ConfigLoader';
import { SiteRouter } from '../../source/SiteRouter';
import { PlayUrlParser } from '../../source/PlayUrlParser';
import { ParseResolver, ParseResult } from '../../source/ParseResolver';
import { AppTheme } from '../../../commons/theme/AppTheme';
import { EpisodeDialog } from '../component/EpisodeDialog';
import {
  PlayerControls, ASPECT_FIT, ASPECT_FILL, ASPECT_16_9, ASPECT_4_3
} from '../component/PlayerControls';
import { PlayerTracksDialog } from '../component/PlayerTracksDialog';
import { PlayerGestureLayer } from '../../../commons/component/PlayerGestureLayer';
import { VolumePanelHost } from '../../../commons/component/VolumePanelHost';
import { PlayDataStore } from '../../../commons/utils/PlayDataStore';
import { AppSettings, AppSettingsData } from '../../../commons/utils/SettingsUtil';
import { UrlUtil } from '../../../commons/utils/UrlUtil';
import { Log } from '../../../commons/utils/LogUtil';
import { ScreenUtil } from '../../../commons/utils/ScreenUtil';
import { BrightnessUtil } from '../../../commons/utils/BrightnessUtil';
import { VolumeUtil } from '../../../commons/utils/VolumeUtil';
import { CastUtil, CastMedia } from '../../../commons/utils/CastUtil';
import { ShareUtil } from '../../../commons/utils/ShareUtil';
import { IntroMark, IntroMarkStore } from '../../../commons/utils/IntroMarkStore';
import { ToastUtil } from '../../../commons/utils/ToastUtil';
import { AppLifecycleUtil } from '../../../commons/utils/AppLifecycleUtil';
import {
  AudioFocusUtil, FOCUS_NONE, FOCUS_PAUSE, FOCUS_RESUME, FOCUS_UNDUCK
} from '../../../commons/utils/AudioFocusUtil';
import { PlayerErrorUtil } from '../../../commons/utils/PlayerErrorUtil';

const TAG = 'VideoPlayer';
const HIDE_DELAY_MS = 3500;
/** 每隔多久把进度写一次 preferences —— 只靠 aboutToDisappear 落盘，被系统杀进程就白看了 */
const PROGRESS_SAVE_INTERVAL_MS = 10000;
/** 续播 seek 的兜底等待：个别片源 seekDone 不回调，超时就强行起播 */
const RESUME_GUARD_MS = 2000;
/** 续播提示浮层的停留时间 */
const RESUME_HINT_MS = 1600;
/** 播完一集后，等多久自动进下一集（倒计时期间可取消） */
const UP_NEXT_SECONDS = 5;
/** 播放失败自动重连的间隔 */
const RECONNECT_DELAY_MS = 1500;
/**
 * 续播时 seekDone 超时后**重发 seek** 的次数上限。
 * 只重发不出错的状态机问题（`5400102 Operation not allowed` 一类）很常见，
 * 早先超时就直接 playFromCurrent()，等于放弃续播 —— 用户看到的就是「从 0 开始播」。
 */
const RESUME_SEEK_RETRY_MAX = 1;
/**
 * `play()` 被拒（典型 5400102：调用时状态不是 prepared/paused/completed）后的重试。
 * 起播瞬间状态常常还在跳，重试一次基本就落地了，比直接给用户报错强得多。
 */
const PLAY_RETRY_MAX = 1;
/** 起播重试的间隔 */
const PLAY_RETRY_DELAY_MS = 400;
/**
 * 续播落点与目标的容许偏差（毫秒）。
 * 播放器 seek 通常落在最近的关键帧上，偏几秒很正常；
 * 但**偏出 15 秒就说明这次 seek 根本没生效**（典型是它落回了 0）——
 * 这时要重发一次，否则用户看到的就是「从 0 开始播」。
 */
const RESUME_SEEK_TOLERANCE_MS = 15000;
/**
 * 控制条可见时，**横滑手势**要避开的底部保留区高度（vp）。
 * 底栏两行 = 进度行 24 + 动作行 44 + 下边距 8 ≈ 76，留到 100 的余量。
 * ⚠️ 现在手势层是包住控制层的**父容器**，高度不用再裁剪（它是 100%）——
 *    这个值只作为 `bottomReservedH` 传下去，用来判断「本次横滑是不是从进度条那一带起手」。
 *    纵向的亮度 / 音量不受它限制（用户反馈过：进度条显示时也要能调亮度）。
 */
const GESTURE_BOTTOM_GAP = 100;

@Entry
@Component
struct VideoPlayerPage {
  @StorageProp('safeTopPx') safeTopPx: number = 0;

  @State title: string = '';
  @State epName: string = '';
  @State sourceName: string = '';
  @State playing: boolean = false;
  @State isFullscreen: boolean = true;
  @State showControls: boolean = true;
  @State positionSec: number = 0;
  @State durationSec: number = 0;
  @State speed: number = 1.0;
  @State statusText: string = '准备中…';
  @State epCount: number = 0;
  @State epIndex: number = 0;
  /** 连播开关：关掉后播完只停住，不自动下一集 */
  @State autoNext: boolean = true;
  /** 当前线路的清晰度标签 */
  @State quality: string = '';
  /** 片源是否有可切换的音轨/字幕 */
  @State hasTracks: boolean = false;

  /* ---------- 「即将播放下一集」浮层 ---------- */
  @State upNextVisible: boolean = false;
  @State upNextName: string = '';
  @State upNextCountdown: number = 0;

  private vod: VodItem = new VodItem();
  private sources: PlaySourceModel[] = [];
  private curSource: number = 0;
  private curEpisode: number = 0;
  private site: SiteModel | undefined = undefined;

  private avPlayer: media.AVPlayer | undefined = undefined;
  private surfaceId: string = '';
  private xController: XComponentController = new XComponentController();

  private hideTimer: number = -1;
  private dialogCtrl: CustomDialogController | undefined = undefined;
  private started: boolean = false;
  /** XComponent 表面是否已就绪。起播要等「表面就绪 + 源已解析」两个条件，见 maybeStart() */
  private surfaceReady: boolean = false;
  private previewSeeking: boolean = false;
  private savedPositionMs: number = 0;
  private initialPositionMs: number = 0;
  private lastError: string = '';

  /* ---------- 续播 ---------- */
  /** 路由带进来的偏好线路名：线路排序会变，靠名字才能对齐 */
  private preferSourceName: string = '';
  /** 路由要求强制横屏（详情页小窗「放大」进来），优先级高于设置里的默认全屏 */
  private forceLandscape: boolean = false;
  /** 已下发 seek 但还没等到 seekDone 的续播位置；0 表示没有待续播 */
  private pendingResumeMs: number = 0;
  private resumeGuardTimer: number = -1;
  /** 已经为这次续播重发过几次 seek（见 RESUME_SEEK_RETRY_MAX） */
  private resumeSeekRetry: number = 0;
  /**
   * 「用户想播」的意图，和播放器状态解耦。
   * `play()` 只能在实际处于 prepared/paused/completed 时调，起播瞬间状态还在跳，
   * 直接调会拿到 5400102（Operation not allowed）—— 表现就是「起播失败 5400102」但片子其实能播。
   * 所以：想播就置位，由 pumpPlay() 在状态合法时真正下发。
   */
  private wantPlay: boolean = false;
  /** 已经有一个 play() 在飞，避免连续下发（第二次必然 5400102） */
  private playInFlight: boolean = false;
  private playRetry: number = 0;
  /** 收到 initialized 时表面还没就绪 → 等 onLoad 再补 surfaceId + prepare() */
  private pendingPrepare: boolean = false;
  private hintTimer: number = -1;
  /** 周期落盘游标 */
  private lastSavedMs: number = 0;
  /** 播放器回过 completed —— 判定「已看完」的主依据 */
  private reachedEnd: boolean = false;

  /* ---------- 片头/片尾标记的自动生效 ---------- */
  /**
   * 本集是否已经自动跳过片头。**每集只跳一次**：跳完之后用户要是自己拖回片头重看，
   * 不能再把他拽走。
   */
  private introAutoSkipped: boolean = false;
  /** 本集是否已经自动过片尾（防止同一集反复触发切集） */
  private outroAutoSkipped: boolean = false;

  /* ---------- 前后台 / 音频焦点 ---------- */
  /**
   * 进后台之前是不是在播。回前台要按它决定「要不要接着播」——
   * 用户反馈的「切回前台不自动播放（偶发）」就是这里没恢复。
   */
  private wasPlayingBeforeBackground: boolean = false;
  /** 被系统音频焦点中断（来电 / 别的播放器）而暂停的，拿到 RESUME 才自动接着播 */
  private pausedByInterrupt: boolean = false;
  /** 绑在 AppLifecycleUtil 上的回调必须留引用，否则 off 不掉 */
  private readonly cbAppForeground: () => void = () => {
    this.onAppForeground();
  };
  private readonly cbAppBackground: () => void = () => {
    this.onAppBackground();
  };

  /* ---------- 多集连播 / 进度聚合 ---------- */
  /** 已看完集的位图（内存镜像）。落盘走 mergeHistory，这里只用于集列表打标 */
  private watchedMask: string = '';
  private upNextTimer: number = -1;
  private upNextEpisode: number = -1;
  /** 播放失败允许自动重连的次数与已用次数（来自设置页） */
  private reconnectTimes: number = 1;
  private retried: number = 0;
  private reconnectTimer: number = -1;

  /* ---------- 音轨 / 字幕 ---------- */
  private audioTracks: TrackOption[] = [];
  private subtitleTracks: TrackOption[] = [];
  private curAudioIndex: number = -1;
  private curSubIndex: number = -1;
  private tracksLoaded: boolean = false;
  private tracksCtrl: CustomDialogController | undefined = undefined;

  /* ---------- 画面比例（防止拉伸） ---------- */
  /**
   * 视频原始宽高，来自 AVPlayer 的 videoSizeChange。
   * XComponent 的 surface 是「拉伸填满自己」的，不会自动保持比例——
   * 竖屏放 4:3 老片、横屏放竖屏短剧都会把人脸拉变形，必须自己算尺寸。
   */
  @State videoW: number = 0;
  @State videoH: number = 0;

  /* ---------- 统一手势层 / 更多面板新增状态 ---------- */
  /** 已缓冲到的位置（秒），来自 bufferingUpdate 的 CACHED_DURATION */
  @State bufferedSec: number = 0;
  /** 画面比例模式 */
  @State aspectMode: number = ASPECT_FIT;
  /** 锁屏中：隐藏所有控制，只留解锁按钮 */
  @State locked: boolean = false;
  /** 手势层用的当前亮度（0~1）。⚠️ 不能叫 brightness，会和 ArkUI 内置属性冲突 */
  @State brightLevel: number = 0.6;
  /** 手势层用的音量（0~1），同时也是提示里的百分比 */
  @State volume: number = 1;
  /**
   * 系统媒体音量等级（0~15 那种），交给根节点常驻的 `VolumePanelHost`。
   * 改它 = 真的改系统音量（三方应用唯一可行途径，详见 VolumeUtil 注释）。
   * ⚠️ 初值给 -1（越界，会被系统丢弃）而不是 0：0 是合法音量（静音），
   * 拿来当"还没读到"的占位值会把用户音量清零。
   * ⚠️ 承载它的 AVVolumePanel 只能挂在 Stack 第一个子节点上，别搬进控制层（见 VolumePanelHost）。
   */
  @State volumeLevel: number = -1;
  /** 投屏：会话是否就绪 / 是否已连上远端设备 / 设备名 */
  @State castReady: boolean = false;
  @State casting: boolean = false;
  @State castDeviceName: string = '';
  /** 片头 / 片尾范围内时显示的跳过按钮文案（空 = 不显示） */
  @State skipIntroText: string = '';
  @State skipOutroText: string = '';
  @State hasIntroMark: boolean = false;
  @State hasOutroMark: boolean = false;
  /** 片头 / 片尾标记（按片名持久化） */
  private introMark: IntroMark = new IntroMark();
  /** 长按倍速前的倍速，松手还原 */
  private speedBeforeLongPress: number = 1.0;

  /* ---------- 横滑快进 / 快退的旧实现已由 PlayerGestureLayer 接管 ---------- */
  /**
   * 手势绑定区域的实测尺寸（vp），随横竖屏变化，不能读 display（物理尺寸不随旋转变）。
   * 用来算画面的等比尺寸，所以必须是 @State：横竖屏切换后要重新渲染 XComponent。
   */
  @State videoAreaW: number = 0;
  @State videoAreaH: number = 0;

  aboutToAppear(): void {
    this.readParams();
    // 兜底：prepareSources 是异步的，一旦它整体失败就没人再调 maybeStart()，
    // 页面会永远停在加载态，所以这里必须把失败显式转成可见文案。
    this.prepareSources().catch((e: Error) => {
      Log.e(TAG, `prepareSources failed: ${e}`);
      this.statusText = '加载影片信息失败，请返回重试';
    });
    this.applyStartupMode();
    // 亮度手势要有个起点；片头/片尾标记按片名读出来
    BrightnessUtil.capture(this.getUIContext());
    this.brightLevel = BrightnessUtil.current();
    // 音量手势的起点取系统当前音量（用户可能刚按过硬件音量键）
    this.syncVolumeFromSystem();
    this.loadIntroMark();
    // 投播会话：拿到才显示投屏入口
    this.setupCast();
    // 前后台：`onPageShow/onPageHide` 只管路由跳转，按 Home 键不会触发，必须走应用级监听
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx !== undefined && ctx !== null) {
      AppLifecycleUtil.init(ctx);
      AppLifecycleUtil.onForeground(this.cbAppForeground);
      AppLifecycleUtil.onBackground(this.cbAppBackground);
    }
  }

  /* ==================== 前后台：切后台必须停播，回前台按需恢复 ==================== */

  /**
   * 进后台。
   * ⚠️ 不显式 pause 的话，AVPlayer 在某些时序下会**继续解码播放**（用户反馈「切后台偶尔不停」），
   * 而且没有后台播放权限，声音还会以奇怪的方式断续漏出来。这里一律停掉并落盘。
   */
  private onAppBackground(): void {
    this.clearHideTimer();
    this.saveProgress();
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player === undefined) {
      return;
    }
    this.wasPlayingBeforeBackground = player.state === 'playing';
    if (this.wasPlayingBeforeBackground) {
      this.playing = false;
      this.safe(() => player.pause(), 'bg pause');
    }
    Log.i(TAG, `background: wasPlaying=${this.wasPlayingBeforeBackground}`);
  }

  /**
   * 回前台。
   * ① 被焦点中断哑掉的音频流要重新压满（`restoreStreamVolume`）；
   * ② 之前在播的接着播 —— 但被中断过的话不抢回来（交给系统补 RESUME）。
   */
  private onAppForeground(): void {
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player === undefined) {
      return;
    }
    AudioFocusUtil.restoreStreamVolume(player);
    this.syncVolumeFromSystem();
    if (this.pausedByInterrupt) {
      Log.i(TAG, 'foreground: waiting for interrupt RESUME');
      return;
    }
    if (this.wasPlayingBeforeBackground) {
      this.wasPlayingBeforeBackground = false;
      if (player.state === 'paused' || player.state === 'prepared' || player.state === 'completed') {
        this.playing = true;
        this.safe(() => player.play(), 'fg resume');
      }
    }
    Log.i(TAG, `foreground: state=${player.state}`);
  }

  /** 系统音频焦点事件（来电 / 别的播放器抢焦点） */
  private onAudioFocus(kind: number): void {
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player === undefined || kind === FOCUS_NONE) {
      return;
    }
    if (kind === FOCUS_PAUSE) {
      // ⚠️ 必须真的暂停，系统才会在合适的时候回一个 RESUME；
      //    只把界面状态改掉而没有暂停，这条流会一直哑着（就是「声音突然没了」）
      this.pausedByInterrupt = true;
      this.playing = false;
      this.safe(() => player.pause(), 'focus pause');
      return;
    }
    if (kind === FOCUS_RESUME) {
      AudioFocusUtil.restoreStreamVolume(player);
      if (this.pausedByInterrupt) {
        this.pausedByInterrupt = false;
        this.playing = true;
        this.safe(() => player.play(), 'focus resume');
      }
      return;
    }
    // DUCK / UNDUCK 由系统自己压音量，这里只把系统音量重新同步一次
    if (kind === FOCUS_UNDUCK) {
      this.syncVolumeFromSystem();
    }
  }

  /** 把手势层的音量基准同步成系统当前音量 */
  private syncVolumeFromSystem(): void {
    VolumeUtil.syncFromSystem();
    this.volumeLevel = VolumeUtil.currentLevel();
    this.volume = VolumeUtil.ratio();
  }

  /**
   * 建立投播会话（AVSession），并把播控中心下发的指令接到本地播放器上。
   * 会话建不起来就不显示投屏入口 —— 没有会话的 AVCastPicker 点了也搜不到设备。
   */
  private setupCast(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    CastUtil.onRemotePlay = () => {
      const player: media.AVPlayer | undefined = this.avPlayer;
      if (player !== undefined && player.state === 'paused') {
        this.safe(() => player.play(), 'cast play');
      }
    };
    CastUtil.onRemotePause = () => {
      const player: media.AVPlayer | undefined = this.avPlayer;
      if (player !== undefined && player.state === 'playing') {
        this.safe(() => player.pause(), 'cast pause');
      }
    };
    CastUtil.onRemoteStop = () => {
      const player: media.AVPlayer | undefined = this.avPlayer;
      if (player !== undefined) {
        this.safe(() => player.pause(), 'cast stop');
      }
    };
    CastUtil.onRemoteSeek = (ms: number) => {
      this.doSeek(Math.floor(ms / 1000));
    };
    CastUtil.onDeviceChanged = (connected: boolean, name: string) => {
      this.casting = connected;
      this.castDeviceName = name;
      if (connected) {
        this.toast(`已投屏到「${name}」，本机停止播放`);
        // 本端让位给远端：系统播控中心会接管远端的播放控制
        const player: media.AVPlayer | undefined = this.avPlayer;
        if (player !== undefined && player.state === 'playing') {
          this.safe(() => player.pause(), 'cast handover');
        }
      } else {
        this.toast('投屏已断开');
      }
    };
    CastUtil.ensureSession(ctx).then((ok: boolean) => {
      this.castReady = ok;
      if (ok) {
        // 起播通常比建会话快，这里补发一次元数据，否则播控中心是空的
        CastUtil.flushMedia().catch((e: Error) => {
          Log.w(TAG, `flushMedia failed: ${e}`);
        });
      } else {
        Log.w(TAG, 'cast session unavailable, hide cast entry');
      }
    }).catch((e: Error) => {
      Log.w(TAG, `ensureSession failed: ${e}`);
    });
  }

  /**
   * 点投屏图标：拉起系统的设备选择面板。
   * 图标颜色由 `casting` 决定（CastUtil 判定），系统的红/白状态不再影响我们。
   */
  private openCastPicker(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    CastUtil.showPicker(ctx).catch((e: Error) => {
      Log.w(TAG, `showPicker failed: ${e}`);
    });
  }

  /**
   * 把当前这一集的最终地址与元数据交给会话。
   * 必须在**拿到最终直链之后**调（`startPlayUrl` 里）—— 采集站的 playUrl 是
   * 整部剧的线路串，得经过解析链才有真实可拉取的地址，把线路串推给远端就是黑屏。
   */
  private pushCastMedia(url: string): void {
    if (url.length === 0) {
      return;
    }
    const mediaInfo: CastMedia = new CastMedia(
      `${this.vod.name}_${this.curSource}_${this.curEpisode}`,
      this.vod.name,
      this.epName,
      this.durationSec * 1000,
      url
    );
    CastUtil.setMedia(mediaInfo).catch((e: Error) => {
      Log.w(TAG, `setMedia failed: ${e}`);
    });
  }

  /** 读这部片的片头/片尾标记（按片名） */
  private loadIntroMark(): void {
    if (this.vod.name.length === 0) {
      return;
    }
    IntroMarkStore.load(this.vod.name).then((m: IntroMark) => {
      this.introMark = m;
      this.hasIntroMark = m.introEndSec > 0;
      this.hasOutroMark = m.outroStartSec > 0;
      this.refreshSkipButtons();
      Log.i(TAG, `intro mark intro=${m.introEndSec} outro=${m.outroStartSec}`);
    }).catch((e: Error) => {
      Log.w(TAG, `loadIntroMark failed: ${e}`);
    });
  }

  aboutToDisappear(): void {
    this.clearHideTimer();
    this.clearResumeGuard();
    this.clearHintTimer();
    this.clearUpNext();
    this.clearReconnectTimer();
    // 先摘前后台监听再收播放器，否则回调可能打在已经释放的 player 上
    AppLifecycleUtil.offForeground(this.cbAppForeground);
    AppLifecycleUtil.offBackground(this.cbAppBackground);
    this.saveProgress();
    this.releasePlayer();
    // 投屏会话跟着页面一起收掉（否则投播会挂着一个已经没了的页面）
    CastUtil.release().catch((e: Error) => {
      Log.w(TAG, `release cast failed: ${e}`);
    });
    // 页面没了就把常亮交还给系统
    this.applyKeepScreenOn(false);
    // 亮度手势改过窗口亮度的话，退出时还原
    BrightnessUtil.restore(this.getUIContext());
    this.exitLandscape();
    // 通知「我的」页刷新播放历史
    const v: number | undefined = AppStorage.get<number>('historyVersion');
    AppStorage.setOrCreate('historyVersion', (v === undefined ? 0 : v) + 1);
  }

  /**
   * 应用设置页里的播放偏好：连播、自动重连、默认倍速、是否默认全屏。
   * 设置读取是异步的，起播不依赖它（只有倍速会晚一步生效）。
   */
  private async applyStartupMode(): Promise<void> {
    let s: AppSettingsData | undefined = undefined;
    try {
      s = await AppSettings.ensure();
    } catch (e) {
      Log.w(TAG, `load settings failed: ${e}`);
    }
    if (s !== undefined) {
      this.autoNext = s.autoNext;
      this.reconnectTimes = s.reconnectTimes;
      this.speed = s.defaultSpeed;
      this.isFullscreen = s.autoFullscreen;
    }
    // 小窗「放大」进来的：必须是横屏，设置里关掉了默认全屏也不能拦
    if (this.forceLandscape) {
      this.isFullscreen = true;
    }
    this.applyLandscape(this.isFullscreen);
  }

  private toggleAutoNext(): void {
    this.autoNext = !this.autoNext;
    AppSettings.current().autoNext = this.autoNext;
    AppSettings.save().catch((e: Error) => {
      Log.w(TAG, `saveAutoNext failed: ${e}`);
    });
    Log.i(TAG, `autoNext=${this.autoNext}`);
    // 播放中关掉：把已经弹出的倒计时收回去
    if (!this.autoNext && this.upNextVisible) {
      this.clearUpNext();
      this.statusText = '已取消自动连播';
    }
  }

  /** 从网页嗅探页返回时带回的直链 */
  onPageShow(): void {
    const sniffed: string | undefined = AppStorage.get<string>('sniff_result_url');
    if (sniffed !== undefined && sniffed.length > 0) {
      AppStorage.setOrCreate('sniff_result_url', '');
      Log.i(TAG, `use sniffed url`);
      this.startPlayUrl(sniffed, undefined, '网页嗅探');
    }
  }

  build() {
    Column() {
      /* ---------- 视频区（Stack 内的子元素尺寸必须显式给，Stack 不是线性布局） ---------- */
      Stack({ alignContent: Alignment.Center }) {
        /*
         * ==================== 统一手势层 = 画面 + 控制层的**父容器** ====================
         * （2026-10-12 终版，用户 + 华为官方文档双确认）
         *
         * 官方《多层级手势事件》给的是**父子**关系，不是兄弟关系：
         *   · 响应优先级 1 —— **父子组件均绑定同一类手势时，子组件优先于父组件触发**；
         *   · `HitTestMode.Default` —— 自身如果命中会阻塞兄弟组件，**但是不阻塞子组件**；
         *   · 触摸测试「自上而下遍历……再把结果逐级向上冒泡至父组件」→ 父容器**永远在响应链上**，
         *     不会出现「Touch test result is empty」这种整个画面一起失灵的情况。
         *
         * 所以把画面 + 控制层全部作为插槽内容塞进来：按钮是**子**、手势是**父**，
         * 按钮的 onClick 天然优先，空白处才轮到本层 —— 两边同时可用。
         * ⚠️⚠️ 别再把它拆回 Stack 里的兄弟透明层，也别再靠 z 序 / 手势层高度去凑：
         *   兄弟之间只有「谁在上谁赢」，必然二选一（前面五六个版本都栽在这里）。
         */
        PlayerGestureLayer({
          active: true,
          locked: this.locked,
          durationSec: this.durationSec,
          positionSec: this.positionSec,
          areaW: this.videoAreaW,
          areaH: this.videoAreaH,
          brightLevel: this.brightLevel,
          volume: this.volume,
          // 控制栏可见时底部那一条留给进度条（横滑不再接管；纵向亮度/音量不受限）
          bottomReservedH: this.showControls ? GESTURE_BOTTOM_GAP : 0,
          onSingleTap: () => {
            this.toggleControls();
          },
          onDoubleTap: () => {
            this.togglePlay();
          },
          onLongPressStart: () => {
            this.startLongPressSpeed();
          },
          onLongPressEnd: () => {
            this.endLongPressSpeed();
          },
          onSeekPreview: (sec: number) => {
            this.previewSeeking = true;
            this.positionSec = sec;
          },
          onSeekTo: (sec: number) => {
            this.doSeek(sec);
          },
          onSeekCancel: () => {
            // 手势被取消：把「预览中」标记清掉，否则 timeUpdate 会一直被压制
            this.previewSeeking = false;
          },
          onBrightness: (v: number) => {
            this.brightLevel = v;
            BrightnessUtil.set(this.getUIContext(), v);
          },
          onVolume: (v: number) => {
            this.volume = v;
            this.applyVolume(v);
          }
        }) {
          /*
           * 系统音量面板宿主（常驻，只此一处）。
           * 它内部是 UIExtensionComponent，会吃掉整条触摸事件（见 VolumePanelHost 头部注释），
           * 所以整棵子树都用 BLOCK_DESCENDANTS 关掉触摸测试 —— 别改成 None。
           */
          VolumePanelHost({ volumeLevel: this.volumeLevel })

          /*
           * 画面按真实比例等比摆放、居中，四周多出来的地方由 Stack 的黑底补成黑边。
           * 尺寸不能写死 100%：surface 会直接拉伸填满，人脸会变形。
           */
          XComponent({
            id: 'vhub_video',
            type: XComponentType.SURFACE,
            controller: this.xController
          })
            .onLoad(() => {
              const id: string = this.xController.getXComponentSurfaceId();
              const changed: boolean = id !== this.surfaceId;
              this.surfaceId = id;
              Log.i(TAG, `surfaceId=${this.surfaceId}`);
              /*
               * 表面被重建过（改过尺寸 / 方向后 ArkUI 重新给了一块）：把新 surfaceId 重挂回播放器。
               * 官方明确允许在 prepared/playing/paused/completed 状态下**再次设置** surfaceId
               * （前提是 initialized 阶段设过一次）。不重挂的话画面就黑在那儿，
               * 播放器侧还可能抛出「操作不允许」。
               */
              const player: media.AVPlayer | undefined = this.avPlayer;
              if (changed && player !== undefined && this.surfaceId.length > 0) {
                const st: media.AVPlayerState = player.state;
                if (st === 'prepared' || st === 'playing' || st === 'paused' || st === 'completed') {
                  this.attachSurface(player, 're-attach');
                }
              }
              this.onSurfaceReady();
            })
            .onDestroy(() => {
              this.surfaceId = '';
            })
            .width(this.renderW())
            .height(this.renderH())
            .backgroundColor('#000000')

          /* 控制层 */
          if (this.showControls || this.locked) {
            PlayerControls({
              title: this.title,
              epName: this.epName,
              playing: this.playing,
              isFullscreen: this.isFullscreen,
              positionSec: this.positionSec,
              durationSec: this.durationSec,
              bufferedSec: this.bufferedSec,
              speed: this.speed,
              statusText: this.statusText,
              sourceName: this.sourceName,
              epCount: this.epCount,
              epIndex: this.epIndex,
              autoNext: this.autoNext,
              quality: this.quality,
              hasTracks: this.hasTracks,
              aspectMode: this.aspectMode,
              locked: this.locked,
              skipIntroText: this.skipIntroText,
              skipOutroText: this.skipOutroText,
              hasIntroMark: this.hasIntroMark,
              hasOutroMark: this.hasOutroMark,
              castReady: this.castReady,
              casting: this.casting,
              castDeviceName: this.castDeviceName,
              onToggleLock: () => {
                this.toggleLock();
              },
              onAspect: (mode: number) => {
                this.changeAspect(mode);
              },
              onShare: () => {
                this.shareCurrent();
              },
              onCast: () => {
                this.openCastPicker();
              },
              onMarkIntro: () => {
                this.markIntro();
              },
              onMarkOutro: () => {
                this.markOutro();
              },
              onSkipIntro: () => {
                this.doSeek(this.introMark.introEndSec);
              },
              onSkipOutro: () => {
                // 片尾标记就是「这集没内容了」，跳过 = 直接进下一集
                this.switchTo(this.curSource, this.curEpisode + 1);
              },
              onToggleAutoNext: () => {
                this.toggleAutoNext();
              },
              onOpenTracks: () => {
                this.openTracksDialog();
              },
              onBack: () => {
                this.goBack();
              },
              onPlayPause: () => {
                this.togglePlay();
              },
              onSeek: (sec: number) => {
                this.doSeek(sec);
              },
              onSeekPreview: (sec: number) => {
                this.previewSeeking = true;
                this.positionSec = sec;
              },
              onToggleFullscreen: () => {
                this.toggleFullscreen();
              },
              onOpenEpisodes: () => {
                this.openEpisodeDialog();
              },
              onPrev: () => {
                this.switchTo(this.curSource, this.curEpisode - 1);
              },
              onNext: () => {
                this.switchTo(this.curSource, this.curEpisode + 1);
              },
              onSpeed: (v: number) => {
                this.changeSpeed(v);
                this.scheduleHideControls();
              },
              onToggleControls: () => {
                this.toggleControls();
              }
            })
              .width('100%')
              .height('100%')
          }

          /*
           * 「即将播放下一集」浮层。
           * 用 hitTestBehavior(Transparent)：按钮自己可点，空白处继续往下透传，
           * 否则倒计时期间点画面就唤不出控制栏了。
           */
          if (this.upNextVisible) {
            Column() {
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Text('即将播放下一集')
                    .fontSize(11)
                    .fontColor('#B9BFCC')
                    .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
                  Text(this.upNextName)
                    .fontSize(14)
                    .fontColor('#FFFFFF')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .hitTestBehavior(HitTestMode.None)

                Text(`${this.upNextCountdown}s`)
                  .fontSize(13)
                  .fontColor(AppTheme.ACCENT)
                  .fontWeight(FontWeight.Bold)
                  .width(34)
                  .textAlign(TextAlign.Center)
                  .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)

                Text('取消')
                  .fontSize(12)
                  .fontColor('#D6DAE3')
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .backgroundColor('rgba(255,255,255,0.14)')
                  .borderRadius(6)
                  .onClick(() => {
                    this.cancelUpNext();
                  })
                  .hitTestBehavior(HitTestMode.Transparent)

                Text('立即播放')
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .backgroundColor(AppTheme.ACCENT)
                  .borderRadius(6)
                  .onClick(() => {
                    this.playUpNextNow();
                  })
                  .hitTestBehavior(HitTestMode.Transparent)
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .backgroundColor('rgba(0,0,0,0.72)')
              .borderRadius(10)
              .hitTestBehavior(HitTestMode.None)
            }
            .width('100%')
            .height('100%')
            .padding({ left: 20, right: 20, bottom: 96 })
            .justifyContent(FlexAlign.End)
            .hitTestBehavior(HitTestMode.None)
          }
        /* ==================== 手势层插槽内容到此结束（它是 PlayerGestureLayer 的子节点） ==================== */
        }
      }
      .width('100%')
      .height(this.isFullscreen ? '100%' : this.videoBoxHeight())
      .backgroundColor('#000000')
      // 「铺满」模式下画面会超出视频区，靠 clip 把溢出部分裁掉（真·裁边，而不是拉伸）
      .clip(true)
      .onAreaChange((oldArea: Area, newArea: Area) => {
        // 只在真正变了的时候写：这是 @State，多余的赋值会白白触发一轮重渲染
        const w: number = newArea.width as number;
        const h: number = newArea.height as number;
        if (Math.abs(w - this.videoAreaW) > 0.5 || Math.abs(h - this.videoAreaH) > 0.5) {
          this.videoAreaW = w;
          this.videoAreaH = h;
        }
      })
      /* 手势全部交给 PlayerGestureLayer（贴在画面上的那一层），这里不再挂 PanGesture */

      /* ---------- 竖屏模式下的选集列表（layoutWeight 只在 Column/Row 里生效） ---------- */
      if (!this.isFullscreen) {
        Column() {
          Row() {
            Text('选集')
              .fontSize(14)
              .fontColor(AppTheme.TEXT_PRIMARY)
              .fontWeight(FontWeight.Medium)
            Text(` ${this.sourceName} · 共 ${this.epCount} 集`)
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .layoutWeight(1)
            Text('线路/选集')
              .fontSize(12)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(AppTheme.CARD)
              .borderRadius(AppTheme.RADIUS_PILL)
              .onClick(() => {
                this.openEpisodeDialog();
              })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 8 })

          List({ space: 8 }) {
            ForEach(this.currentEpisodes(), (ep: EpisodeModel) => {
              ListItem() {
                Text(ep.name)
                  .fontSize(13)
                  .fontColor(this.curEpisode === ep.index ? '#FFFFFF' : AppTheme.TEXT_PRIMARY)
                  .backgroundColor(this.curEpisode === ep.index ? AppTheme.ACCENT : AppTheme.CARD)
                  .width('100%')
                  .height(40)
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .borderRadius(8)
                  .onClick(() => {
                    this.switchTo(this.curSource, ep.index);
                  })
              }
            }, (ep: EpisodeModel) => `pep_${this.curSource}_${ep.index}`)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 12 })
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .layoutWeight(1)
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [
            [AppTheme.BG_GRAD_TOP, 0.0],
            [AppTheme.BG_GRAD_MID, 0.5],
            [AppTheme.BG_GRAD_BOTTOM, 1.0]
          ]
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .padding({ top: this.isFullscreen ? 0 : this.getUIContext().px2vp(this.safeTopPx) })
  }

  /* ==================== 生命周期 / 参数 ==================== */

  private readParams(): void {
    try {
      const raw: Object = this.getUIContext().getRouter().getParams();
      if (raw === undefined || raw === null) {
        return;
      }
      const p: PlayerParams = raw as PlayerParams;
      if (p.vod !== undefined && p.vod !== null) {
        this.vod = p.vod;
      }
      this.curSource = p.sourceIndex >= 0 ? p.sourceIndex : 0;
      this.curEpisode = p.episodeIndex >= 0 ? p.episodeIndex : 0;
      this.initialPositionMs = p.positionMs > 0 ? p.positionMs : 0;
      this.preferSourceName = (p.sourceName === undefined || p.sourceName === null) ? '' : p.sourceName;
      this.forceLandscape = p.forceLandscape === true;
      this.title = this.vod.name;
      Log.i(TAG, `params ep=${this.curEpisode} resumeMs=${this.initialPositionMs} src=${this.preferSourceName}`);
    } catch (e) {
      Log.w(TAG, `readParams failed: ${e}`);
    }
  }

  private async prepareSources(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await ConfigManager.get().ensureInit(ctx);
    } catch (e) {
      Log.w(TAG, `ensureInit failed: ${e}`);
    }

    this.site = this.findSite(this.vod.siteKey);
    if (this.vod.playUrl.length === 0) {
      // 包一层：这里会发网络请求，抛出去就会让整个 prepareSources 提前中断，
      // 后面没人再调 maybeStart()，页面会永远停在「正在获取播放地址…」
      try {
        const full: VodItem | undefined = await this.fetchFullDetail();
        if (full !== undefined) {
          if (full.pic.length === 0) {
            full.pic = this.vod.pic;
          }
          this.vod = full;
          this.title = full.name;
          // 走了跨站兜底的话站点会变，重新定位一次（下面 PlayUrlParser 不依赖它，但后续解析要用）
          this.site = this.findSite(full.siteKey);
        }
      } catch (e) {
        Log.e(TAG, `fetchFullDetail failed: ${e}`);
      }
    }

    this.sources = PlayUrlParser.sortByPlayability(
      PlayUrlParser.parse(this.vod.playFrom, this.vod.playUrl));
    // 线路排序会打乱下标，路由带了线路名就以名字为准
    if (this.preferSourceName.length > 0) {
      for (let i = 0; i < this.sources.length; i++) {
        if (this.sources[i].name === this.preferSourceName) {
          this.curSource = i;
          break;
        }
      }
    }
    if (this.curSource >= this.sources.length) {
      this.curSource = 0;
    }
    await this.applyHistoryResume();
    await this.loadWatchedMask();
    this.syncEpisodeState();
    this.buildEpisodeDialog();

    // 源解析完了：要么起播，要么说清是哪一种「播不了」，别一律甩「没有可播放的地址」
    if (this.sources.length === 0) {
      this.statusText = this.emptyReason();
      Log.w(TAG, `no sources: site=${this.vod.siteKey} id=${this.vod.id} reason=${this.statusText}`);
      return;
    }
    this.maybeStart();
  }

  /** sources 为空的准确原因，便于用户判断该换源还是换站 */
  private emptyReason(): string {
    if (this.site === undefined) {
      return '这部影片的来源已失效，也没在其它源里找到它';
    }
    return '这个来源没有给出播放地址，试试换线路或换源';
  }

  /**
   * 读一次已看集位图，用于集列表打标。
   * 单独查一次 findHistory（而不是复用 applyHistoryResume 的结果）：
   * 后者在路由带了 positionMs 时会提前返回，拿不到位图。
   */
  private async loadWatchedMask(): Promise<void> {
    if (this.vod.id.length === 0) {
      return;
    }
    try {
      const rec: PlayRecord | undefined = await PlayDataStore.findHistory(this.vod.siteKey, this.vod.id);
      if (rec !== undefined) {
        this.watchedMask = rec.watchedMask;
      }
    } catch (e) {
      Log.w(TAG, `loadWatchedMask failed: ${e}`);
    }
  }

  /**
   * 路由没带续播位置时自己查一次历史。
   * 双保险：详情页/历史页都会传 positionMs，但万一入口漏传，这里也能续上。
   * 只在「停留在历史记录的那一集」时生效——用户主动点了别的集就必须从头播。
   */
  private async applyHistoryResume(): Promise<void> {
    if (this.vod.id.length === 0) {
      return;
    }
    if (this.initialPositionMs > 0 || this.sources.length === 0) {
      return;
    }
    let rec: PlayRecord | undefined = undefined;
    try {
      rec = await PlayDataStore.findResume(this.vod.name, this.vod.siteKey, this.vod.id);
    } catch (e) {
      Log.w(TAG, `findResume failed: ${e}`);
      return;
    }
    if (rec === undefined) {
      return;
    }
    // 跨站记录不在这层用：集序号对不上，得由详情页按集名对齐后再把 positionMs 传进来
    if (rec.siteKey !== this.vod.siteKey || rec.vodId !== this.vod.id) {
      return;
    }
    if (rec.sourceName.length > 0 && this.preferSourceName.length === 0) {
      for (let i = 0; i < this.sources.length; i++) {
        if (this.sources[i].name === rec.sourceName) {
          this.curSource = i;
          break;
        }
      }
    }
    if (rec.episodeIndex !== this.curEpisode) {
      return;
    }
    const at: number = PlayRecord.resumeTargetMs(rec);
    if (at > 0) {
      this.initialPositionMs = at;
      Log.i(TAG, `resume from history ${at}ms`);
    }
  }

  /**
   * 补全详情拿到 playUrl。从历史/收藏进来时只有 vodId + 片名，必须现场拉一次。
   *
   * 两级：
   *   1) 记录里的 siteKey 还在当前配置里 → 直接问这个站；
   *   2) 不在（用户换过配置源，旧 key/vodId 全都失效）或该站没给地址 →
   *      按**片名**到其它可用站搜一遍再取详情。
   * 第 2 级是必要的：历史记录存的是「当时那个站」，换源后 siteKey 一定对不上，
   * 没有兜底就永远点不开了。思路和 PlayDataStore.findResume() 的按名兜底一致。
   */
  private async fetchFullDetail(): Promise<VodItem | undefined> {
    if (this.site !== undefined) {
      const full: VodItem | undefined = await SiteRouter.detail(this.site, this.vod.id);
      if (full !== undefined && full.playUrl.length > 0) {
        return full;
      }
      Log.w(TAG, `detail miss on site=${this.vod.siteKey} id=${this.vod.id}`);
    }

    if (this.vod.name.length === 0) {
      return undefined;
    }
    const cfg = ConfigManager.get();
    if (cfg.sites.length === 0) {
      return undefined;
    }
    let hits: VodItem[] = [];
    try {
      hits = await SiteRouter.searchAll(cfg.sites, this.vod.name, 1);
    } catch (e) {
      Log.w(TAG, `fallback search failed: ${e}`);
      return undefined;
    }

    // 片名完全相同才作数，避免「同名不同剧」搜出别的片子
    let hit: VodItem | undefined = undefined;
    for (let i = 0; i < hits.length; i++) {
      if (hits[i].name === this.vod.name) {
        hit = hits[i];
        break;
      }
    }
    if (hit === undefined) {
      Log.w(TAG, `fallback: no exact name match for "${this.vod.name}" (${hits.length} hits)`);
      return undefined;
    }
    const alt: SiteModel | undefined = this.findSite(hit.siteKey);
    if (alt === undefined) {
      return undefined;
    }
    Log.i(TAG, `fallback to site=${hit.siteKey} id=${hit.id}`);
    const full2: VodItem | undefined = await SiteRouter.detail(alt, hit.id);
    return full2;
  }

  private findSite(key: string): SiteModel | undefined {
    const cfg = ConfigManager.get();
    for (let i = 0; i < cfg.sites.length; i++) {
      if (cfg.sites[i].key === key) {
        return cfg.sites[i];
      }
    }
    for (let i = 0; i < cfg.allSites.length; i++) {
      if (cfg.allSites[i].key === key && cfg.isUsable(cfg.allSites[i])) {
        return cfg.allSites[i];
      }
    }
    return undefined;
  }

  /* ==================== 播放控制 ==================== */

  private onSurfaceReady(): void {
    this.surfaceReady = true;
    /*
     * 补一波「表面比状态机慢」：收到 initialized 时 surfaceId 还是空的，
     * 那时我们只能先记下 pendingPrepare；现在表面来了，把这两步补上。
     * 不补的话播放器会永远停在 initialized —— 界面就是一直「缓冲中…」+ 00:00/00:00。
     */
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (this.pendingPrepare && player !== undefined && player.state === 'initialized') {
      if (this.attachSurface(player, 'prepare(surface ready)') && this.safePrepare(player)) {
        this.pendingPrepare = false;
        return;
      }
    }
    this.maybeStart();
  }

  /**
   * 给播放器挂 surface。`player.surfaceId = xx` 在状态不对时会**同步抛**（5400102），
   * 抛在 stateChange 回调里没人接得住，所以一律走这里包一层。
   */
  private attachSurface(player: media.AVPlayer, what: string): boolean {
    if (this.surfaceId.length === 0) {
      Log.w(TAG, `attachSurface(${what}) skipped: empty surfaceId`);
      return false;
    }
    try {
      player.surfaceId = this.surfaceId;
      return true;
    } catch (e) {
      const err = e as BusinessError;
      Log.e(TAG, `attachSurface(${what}) failed ${err.code} ${err.message}`);
      return false;
    }
  }

  /**
   * 起播闸门：必须「表面就绪」且「源已解析」同时满足。
   *
   * 不能像以前那样在 onSurfaceReady 里直接判 sources.length === 0 就报错——
   * prepareSources() 是异步的，而**从历史记录进来时 playUrl 为空，要现场发一次 detail 请求**，
   * 那几百毫秒里 XComponent 表面早就加载完了，于是必然先走到这里、把 started 置成 true，
   * 之后再怎么等都永远不会起播（表现就是点历史记录提示「没有可播放的地址」）。
   * 现在改为「谁后到谁触发」：两边都调 maybeStart()，条件齐了才真正起播。
   */
  private maybeStart(): void {
    if (this.started || !this.surfaceReady) {
      return;
    }
    if (this.sources.length === 0) {
      // 源还在解析（历史续播要拉详情），prepareSources() 完成后会再调一次
      this.statusText = '正在获取播放地址…';
      return;
    }
    this.started = true;
    this.playCurrent();
  }

  /** 播放当前线路的当前集 */
  private async playCurrent(): Promise<void> {
    const eps: EpisodeModel[] = this.currentEpisodes();
    if (eps.length === 0) {
      this.statusText = '该线路没有剧集';
      return;
    }
    if (this.curEpisode < 0 || this.curEpisode >= eps.length) {
      this.curEpisode = 0;
    }
    const ep: EpisodeModel = eps[this.curEpisode];
    this.syncEpisodeState();
    this.statusText = `解析中… ${ep.name}`;
    this.durationSec = 0;
    // 进度游标以「待续播位置」起算：否则起播瞬间就退出的话，会把刚恢复的进度又写回 0
    this.reachedEnd = false;
    // 新一集（或重连）重新给片头/片尾的自动跳过一次机会
    this.introAutoSkipped = false;
    this.outroAutoSkipped = false;
    this.savedPositionMs = this.initialPositionMs > 0 ? this.initialPositionMs : 0;
    this.lastSavedMs = this.savedPositionMs;
    this.positionSec = Math.floor(this.savedPositionMs / 1000);

    const parses = ConfigManager.get().parses;
    let pr: ParseResult = new ParseResult();
    try {
      pr = await ParseResolver.resolve(ep.url, this.site === undefined ? PlaceholderSite.placeholder : this.site,
        parses, -1);
    } catch (e) {
      pr.ok = false;
      pr.error = `${e}`;
      pr.needSniff = true;
    }

    if (!pr.ok || pr.url.length === 0) {
      this.statusText = `解析失败，尝试网页嗅探…`;
      Log.w(TAG, `parse failed: ${pr.error}`);
      this.gotoSniffer(ep.url);
      return;
    }
    this.startPlayUrl(pr.url, pr.headers, pr.parseName);
  }

  private async startPlayUrl(url: string, headers: Record<string, string> | undefined,
    via: string): Promise<void> {
    if (this.surfaceId.length === 0) {
      this.statusText = '视频表面未就绪';
      return;
    }
    this.statusText = `缓冲中…(${via})`;
    try {
      const player: media.AVPlayer = await this.ensurePlayer();
      if (player.state !== 'idle') {
        await player.reset();
      }
      const src: media.MediaSource = headers !== undefined
        ? media.createMediaSourceWithUrl(url, headers)
        : media.createMediaSourceWithUrl(url);
      await player.setMediaSource(src);
      Log.i(TAG, `setMediaSource ok, state=${player.state}`);
      // 拿到最终直链了，登记到投播会话（投屏中换集会顺带推给远端设备）
      this.pushCastMedia(url);
    } catch (e) {
      const err = e as BusinessError;
      this.lastError = `${err.code}: ${err.message}`;
      this.statusText = `播放失败 ${this.lastError}`;
      Log.e(TAG, `startPlayUrl failed ${this.lastError}`);
    }
  }

  /**
   * 把本端播放状态报给投播会话。
   * 不报的话，系统播控中心的按钮和进度条会和实际播放脱节（官方明确要求主动上报）。
   */
  private reportCastState(playing: boolean): void {
    if (!this.castReady) {
      return;
    }
    CastUtil.setState(playing, this.savedPositionMs, this.speed).catch((e: Error) => {
      Log.w(TAG, `reportCastState failed: ${e}`);
    });
  }

  private async ensurePlayer(): Promise<media.AVPlayer> {
    if (this.avPlayer !== undefined) {
      return this.avPlayer;
    }
    const player: media.AVPlayer = await media.createAVPlayer();
    player.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason) => {
      this.onPlayerState(state);
    });
    player.on('timeUpdate', (time: number) => {
      if (!this.previewSeeking) {
        this.positionSec = Math.floor(time / 1000);
        this.refreshSkipButtons();
        // 片头/片尾标记自动生效（用户标了就要自动跳过，而不是只弹个胶囊等手点）
        this.applyMarks();
      }
      this.savedPositionMs = time;
      // 周期落盘：只靠 aboutToDisappear 的话，被系统杀进程就丢进度了
      if (time - this.lastSavedMs >= PROGRESS_SAVE_INTERVAL_MS) {
        this.lastSavedMs = time;
        this.saveProgress();
      }
    });
    // 缓冲进度：CACHED_DURATION 给出已缓存到的时间（毫秒），进度条上那条浅色的就是它
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (infoType === media.BufferingInfoType.CACHED_DURATION) {
        const sec: number = Math.floor(value / 1000);
        if (sec > this.bufferedSec) {
          this.bufferedSec = sec;
        }
      }
    });
    player.on('durationUpdate', (duration: number) => {
      this.durationSec = Math.floor(duration / 1000);
    });
    /*
     * 片源真实分辨率。必须用它来定画面的显示尺寸，否则 surface 会把画面拉伸填满：
     * 「横屏的手机 + 竖屏的短剧」和「竖屏的手机 + 4:3 的老片」都会明显变形。
     */
    player.on('videoSizeChange', (width: number, height: number) => {
      if (width > 0 && height > 0 && (width !== this.videoW || height !== this.videoH)) {
        this.videoW = width;
        this.videoH = height;
        Log.i(TAG, `video size ${width}x${height}`);
      }
    });
    player.on('seekDone', (pos: number) => {
      this.previewSeeking = false;
      if (this.pendingResumeMs <= 0) {
        return;
      }
      const want: number = this.pendingResumeMs;
      this.pendingResumeMs = 0;
      this.clearResumeGuard();
      Log.i(TAG, `resume seekDone want=${want}ms got=${pos}ms`);
      /*
       * 落点离目标太远（尤其是落回 0）说明这次 seek 没生效 —— 重发一次。
       * 不重发就直接 play()，用户看到的就是「续播失效、从 0 开始播」。
       */
      if (Math.abs(pos - want) > RESUME_SEEK_TOLERANCE_MS && this.resumeSeekRetry < RESUME_SEEK_RETRY_MAX) {
        this.resumeSeekRetry = this.resumeSeekRetry + 1;
        this.pendingResumeMs = want;
        Log.w(TAG, `resume landed off target, re-seek ${want}ms (retry ${this.resumeSeekRetry})`);
        if (this.seekToResume(player, want)) {
          this.armResumeGuard(player);
          return;
        }
        this.pendingResumeMs = 0;
      }
      this.resumeSeekRetry = 0;
      this.savedPositionMs = pos;
      this.lastSavedMs = pos;
      this.positionSec = Math.floor(pos / 1000);
      this.showResumeHint(pos);
      this.playFromCurrent(player);
    });
    player.on('error', (err: BusinessError) => {
      Log.e(TAG, `player error ${err.code} ${err.message} state=${player.state}`);
      /*
       * ⚠️ error 事件 **不等于播放失败**。
       * 5400102（Operation not allowed）是纯状态机时序问题：起播瞬间我们在状态切换的夹缝里
       * 下发 seek / play / audioInterruptMode 会被拒，播放器照抛一条 error，但下一秒自己就播上了。
       * 判据统一收在 PlayerErrorUtil（详情页小窗共用），详见该文件头部。
       */
      if (PlayerErrorUtil.shouldIgnore(err.code, player.state)) {
        Log.w(TAG, `ignore transient player error ${err.code} in state ${player.state}`);
        if (!this.playing) {
          this.statusText = '缓冲中…';
        }
        return;
      }
      this.playing = false;
      this.applyKeepScreenOn(false);
      this.statusText = `播放错误 ${err.code}`;
      this.showControls = true;
      this.scheduleReconnect();
    });
    /*
     * 音频焦点：不挂这个的话，被来电 / 别的播放器抢走焦点之后系统会把这条流静音，
     * 但 AVPlayer 的 state 还是 playing、画面继续走 —— 就是「声音突然消失」。
     * 详见 AudioFocusUtil 头部说明。
     */
    AudioFocusUtil.attach(player, (kind: number) => {
      this.onAudioFocus(kind);
    });
    this.avPlayer = player;
    return player;
  }

  /** 起播（无续播）：只登记「想播」，真正下发交给 pumpPlay() */
  private playFromCurrent(player: media.AVPlayer): void {
    this.wantPlay = true;
    this.pumpPlay(player);
    this.scheduleHideControls();
  }

  /**
   * 真正下发 `play()`，但在**状态合法时才发**。
   *
   * 为什么不能直接 play()：
   *   `play()` 只在 prepared / paused / completed 下允许，别的一律 `5400102 Operation not allowed`。
   *   起播那一瞬间状态常常还在 prepared ↔ playing 之间跳（especially 续播 seek 之后），
   *   直接下发就会拿到 5400102 —— 用户看到的「起播失败 5400102」就是这么来的，
   *   而片子其实下一秒自己就播上了。
   * 所以：状态不对就**什么都不做**（等下一次 stateChange 再来催），
   *       状态对但被拒就**隔一小会儿重试**（最多 PLAY_RETRY_MAX 次），全都失败才报错。
   */
  private pumpPlay(player: media.AVPlayer): void {
    if (!this.wantPlay || this.playInFlight) {
      return;
    }
    const st: media.AVPlayerState = player.state;
    if (st !== 'prepared' && st !== 'paused' && st !== 'completed') {
      Log.w(TAG, `play deferred, state=${st}`);
      return;
    }
    this.statusText = '';
    this.playing = true;
    this.retried = 0;
    // 默认倍速：起播后再设置，reset 前设置会被播放器丢掉
    if (Math.abs(this.speed - 1.0) > 0.001) {
      try {
        player.setPlaybackRate(this.speed);
      } catch (e) {
        Log.w(TAG, `apply default speed failed: ${e}`);
      }
    }
    this.playInFlight = true;
    player.play().then(() => {
      this.playInFlight = false;
      this.wantPlay = false;
      this.playRetry = 0;
      Log.i(TAG, 'play started');
    }).catch((e: BusinessError) => {
      this.playInFlight = false;
      Log.e(TAG, `play failed ${e.code} ${e.message} state=${player.state}`);
      if (this.playRetry < PLAY_RETRY_MAX) {
        this.playRetry = this.playRetry + 1;
        const attempt: number = this.playRetry;
        setTimeout(() => {
          Log.i(TAG, `retry play (${attempt}/${PLAY_RETRY_MAX})`);
          this.pumpPlay(player);
        }, PLAY_RETRY_DELAY_MS);
        return;
      }
      this.wantPlay = false;
      this.statusText = `起播失败 ${e.code}`;
    });
  }

  /**
   * 带续播起播。
   * 旧写法是 play() 之后再 seek()，seek 经常被刚起播的缓冲覆盖掉，表现就是「永远从头播」。
   * 正确顺序：prepared 状态下先 seek，等 seekDone 再 play；兜底定时器防止 seekDone 不回调。
   *
   * ⚠️ 兜底超时**不能直接闷头起播**（那等于放弃续播，用户看到「从 0 开始播」）：
   *    先重发一次 seek（seekDone 偶发不回调，但第二次通常就回来了），
   *    重发仍无果才退化成从头播。
   */
  private startWithResume(player: media.AVPlayer, resumeMs: number): void {
    this.pendingResumeMs = resumeMs;
    this.resumeSeekRetry = 0;
    this.savedPositionMs = resumeMs;
    this.lastSavedMs = resumeMs;
    this.positionSec = Math.floor(resumeMs / 1000);
    Log.i(TAG, `resume seek to ${resumeMs}ms`);
    if (!this.seekToResume(player, resumeMs)) {
      this.pendingResumeMs = 0;
      this.playFromCurrent(player);
      return;
    }
    this.armResumeGuard(player);
  }

  /** 下发一次续播 seek；同步抛异常时返回 false */
  private seekToResume(player: media.AVPlayer, ms: number): boolean {
    try {
      player.seek(ms);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      Log.w(TAG, `resume seek threw ${err.code} ${err.message}`);
      return false;
    }
  }

  /** 续播兜底：seekDone 一直不来就先重发 seek，重发完还不来才退化成从头播 */
  private armResumeGuard(player: media.AVPlayer): void {
    this.clearResumeGuard();
    this.resumeGuardTimer = setTimeout(() => {
      this.resumeGuardTimer = -1;
      const target: number = this.pendingResumeMs;
      if (target <= 0) {
        return;
      }
      if (this.resumeSeekRetry < RESUME_SEEK_RETRY_MAX) {
        this.resumeSeekRetry = this.resumeSeekRetry + 1;
        Log.w(TAG, `seekDone timeout, re-seek ${target}ms (retry ${this.resumeSeekRetry})`);
        if (this.seekToResume(player, target)) {
          this.armResumeGuard(player);
          return;
        }
      }
      Log.w(TAG, `resume failed after retry, play from ${target}ms`);
      this.pendingResumeMs = 0;
      this.playFromCurrent(player);
    }, RESUME_GUARD_MS);
  }

  /** 续播成功后给一个短暂的提示，用户能直观看到「确实续上了」 */
  private showResumeHint(posMs: number): void {
    const sec: number = Math.floor(posMs / 1000);
    this.toast(`已从 ${UrlUtil.formatTime(sec)} 继续播放`);
  }

  private clearResumeGuard(): void {
    if (this.resumeGuardTimer !== -1) {
      clearTimeout(this.resumeGuardTimer);
      this.resumeGuardTimer = -1;
    }
  }

  private clearHintTimer(): void {
    if (this.hintTimer !== -1) {
      clearTimeout(this.hintTimer);
      this.hintTimer = -1;
    }
  }

  /* ==================== 音轨 / 字幕 ==================== */

  /**
   * 读取片源的音轨与字幕轨。
   * 必须在 playing 之后调用：prepared 阶段轨道还没解析出来。
   */
  private async loadTracks(): Promise<void> {
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player === undefined) {
      return;
    }
    try {
      const descs: media.MediaDescription[] = await player.getTrackDescription();
      const aud: TrackOption[] = [];
      const sub: TrackOption[] = [];
      for (let i = 0; i < descs.length; i++) {
        const d: media.MediaDescription = descs[i];
        const idx: number = VideoPlayerPage.numOf(d, 'track_index');
        const type: number = VideoPlayerPage.numOf(d, 'track_type');
        const mime: string = VideoPlayerPage.strOf(d, 'codec_mime');
        const t: TrackOption = new TrackOption();
        t.index = idx;
        t.label = mime.length > 0 ? mime : `轨道 ${idx}`;
        if (type === media.MediaType.MEDIA_TYPE_AUD) {
          t.type = media.MediaType.MEDIA_TYPE_AUD;
          aud.push(t);
        } else if (type === media.MediaType.MEDIA_TYPE_SUBTITLE) {
          t.type = media.MediaType.MEDIA_TYPE_SUBTITLE;
          sub.push(t);
        }
      }
      this.audioTracks = aud;
      this.subtitleTracks = sub;
      // 只有一条音轨且没有字幕时不显示入口，免得给用户一个点了没反应的按钮
      this.hasTracks = aud.length > 1 || sub.length > 0;
      Log.i(TAG, `tracks aud=${aud.length} sub=${sub.length}`);
    } catch (e) {
      Log.w(TAG, `getTrackDescription failed: ${e}`);
    }
  }

  private static numOf(d: media.MediaDescription, key: string): number {
    const v: Object = d[key];
    return typeof v === 'number' ? v : -1;
  }

  private static strOf(d: media.MediaDescription, key: string): string {
    const v: Object = d[key];
    return typeof v === 'string' ? v : '';
  }

  private pickTrack(type: number, index: number, label: string): void {
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player === undefined) {
      return;
    }
    const isAudio: boolean = type === media.MediaType.MEDIA_TYPE_AUD;
    if (index < 0) {
      // 关闭字幕：把当前字幕轨取消选择
      const off: number = this.curSubIndex;
      if (off < 0) {
        return;
      }
      player.deselectTrack(off).then(() => {
        this.curSubIndex = -1;
        this.toast('已关闭字幕');
      }).catch((e: BusinessError) => {
        this.toast(`关闭字幕失败 ${e.code}`);
      });
      return;
    }
    player.selectTrack(index).then(() => {
      if (isAudio) {
        this.curAudioIndex = index;
      } else {
        this.curSubIndex = index;
      }
      Log.i(TAG, `selectTrack ${isAudio ? 'audio' : 'subtitle'} ${index} (${label})`);
      this.toast(`已切换：${label}`);
    }).catch((e: BusinessError) => {
      this.toast(`切换失败 ${e.code}`);
    });
  }

  private buildTracksDialog(): void {
    const ctrl: CustomDialogController = new CustomDialogController({
      builder: PlayerTracksDialog({
        audioTracks: this.audioTracks,
        subtitleTracks: this.subtitleTracks,
        currentAudio: this.curAudioIndex,
        currentSubtitle: this.curSubIndex,
        onPick: (type: number, index: number, label: string) => {
          this.pickTrack(type, index, label);
        },
        onClose: () => {
          this.tracksCtrl?.close();
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true
    });
    this.tracksCtrl = ctrl;
  }

  private openTracksDialog(): void {
    this.showControls = true;
    this.clearHideTimer();
    this.buildTracksDialog();
    this.tracksCtrl?.open();
    setTimeout(() => {
      this.scheduleHideControls();
    }, 800);
  }

  /** 线路名里的清晰度标签：源普遍把画质写在源名上（如「高清」「1080P」） */
  private static qualityOf(sourceName: string): string {
    const upper: string = sourceName.toUpperCase();
    if (upper.indexOf('4K') >= 0 || upper.indexOf('2160') >= 0) {
      return '4K';
    }
    if (upper.indexOf('1080') >= 0 || upper.indexOf('BLURAY') >= 0 || sourceName.indexOf('蓝光') >= 0) {
      return '1080P';
    }
    if (upper.indexOf('720') >= 0) {
      return '720P';
    }
    if (upper.indexOf('480') >= 0) {
      return '480P';
    }
    if (sourceName.indexOf('超清') >= 0) {
      return '超清';
    }
    if (sourceName.indexOf('高清') >= 0) {
      return '高清';
    }
    if (sourceName.indexOf('标清') >= 0) {
      return '标清';
    }
    return '';
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1600 });
    } catch (e) {
      Log.w(TAG, `toast failed: ${e}`);
    }
  }

  /* ==================== 播放失败自动重连 ==================== */

  /**
   * 播放中断后带进度重试。
   * stateChange('error') 与 on('error') 可能同时回来，用 reconnectTimer 去重，
   * 否则一次故障会同时消耗两次重连额度。
   */
  private scheduleReconnect(): void {
    if (this.reconnectTimes <= 0 || this.retried >= this.reconnectTimes) {
      return;
    }
    if (this.reconnectTimer !== -1) {
      return;
    }
    this.retried = this.retried + 1;
    const attempt: number = this.retried;
    this.statusText = `播放中断，正在重连（${attempt}/${this.reconnectTimes}）…`;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      if (this.avPlayer === undefined) {
        return;
      }
      // 带进度重试：重连后从刚才的位置继续，而不是跳回片头
      this.initialPositionMs = this.savedPositionMs > 3000 ? Math.floor(this.savedPositionMs) : 0;
      Log.i(TAG, `reconnect ${attempt}/${this.reconnectTimes} at ${this.initialPositionMs}ms`);
      this.playCurrent();
    }, RECONNECT_DELAY_MS);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }

  /* ==================== 播完自动下一集 ==================== */
  /** 一集播完后：还有下一集且开了连播 → 起倒计时；否则给个静态提示 */
  private handleEpisodeEnd(): void {
    const eps: EpisodeModel[] = this.currentEpisodes();
    const next: number = this.curEpisode + 1;
    if (next >= eps.length) {
      this.clearUpNext();
      this.statusText = '已经是最后一集';
      return;
    }
    if (!this.autoNext) {
      this.clearUpNext();
      this.statusText = `本集已播完，点「下一集」继续`;
      return;
    }
    this.startUpNext(next);
  }

  private startUpNext(next: number): void {
    const eps: EpisodeModel[] = this.currentEpisodes();
    if (next < 0 || next >= eps.length) {
      return;
    }
    this.clearUpNext();
    this.upNextEpisode = next;
    this.upNextName = eps[next].name;
    this.upNextCountdown = UP_NEXT_SECONDS;
    this.upNextVisible = true;
    this.statusText = '';
    Log.i(TAG, `up next ep=${next} (${this.upNextName}) in ${UP_NEXT_SECONDS}s`);
    this.upNextTimer = setInterval(() => {
      this.upNextCountdown = this.upNextCountdown - 1;
      if (this.upNextCountdown <= 0) {
        const target: number = this.upNextEpisode;
        this.clearUpNext();
        Log.i(TAG, `auto play next ep=${target}`);
        this.switchTo(this.curSource, target);
      }
    }, 1000);
  }

  /** 用户点了「取消」：停在片尾不动，手动再点「下一集」即可 */
  private cancelUpNext(): void {
    const next: number = this.upNextEpisode;
    this.clearUpNext();
    const eps: EpisodeModel[] = this.currentEpisodes();
    if (next >= 0 && next < eps.length) {
      this.statusText = `已暂停连播，下一集：${eps[next].name}`;
    } else {
      this.statusText = '已取消自动连播';
    }
    this.showControls = true;
  }

  private playUpNextNow(): void {
    const target: number = this.upNextEpisode;
    this.clearUpNext();
    if (target >= 0) {
      this.switchTo(this.curSource, target);
    }
  }

  private clearUpNext(): void {
    if (this.upNextTimer !== -1) {
      clearInterval(this.upNextTimer);
      this.upNextTimer = -1;
    }
    this.upNextVisible = false;
    this.upNextEpisode = -1;
  }

  private onPlayerState(state: media.AVPlayerState): void {
    Log.i(TAG, `player state=${state}`);
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player === undefined) {
      return;
    }
    if (state === 'initialized') {
      if (this.surfaceId.length === 0) {
        /*
         * 表面还没就绪就先记一笔，等 XComponent.onLoad 再补 surfaceId + prepare()。
         * 早先这里直接 return 就再也没人管了，播放器永远停在 initialized ——
         * 界面就是一直「缓冲中…」+ 00:00/00:00。
         */
        this.pendingPrepare = true;
        this.statusText = '视频表面未就绪';
        return;
      }
      if (this.attachSurface(player, 'initialized') && this.safePrepare(player)) {
        this.pendingPrepare = false;
      }
    } else if (state === 'prepared') {
      this.pendingPrepare = false;
      /*
       * 音频焦点模式（SHARE_MODE）只能在这里设 —— idle 下设会招来 5400102 误报，
       * 详情页小窗就是被它坑的（详见 AudioFocusUtil.applyInterruptMode）。
       */
      AudioFocusUtil.applyInterruptMode(player);
      // 缓冲完就上常亮：马上要出画了，别在这几秒撞上灭屏计时
      this.applyKeepScreenOn(true);
      const resumeMs: number = this.initialPositionMs;
      this.initialPositionMs = 0;
      if (resumeMs > 0) {
        this.startWithResume(player, resumeMs);
      } else {
        this.playFromCurrent(player);
      }
    } else if (state === 'playing') {
      this.playing = true;
      this.statusText = '';
      // 真的在播了：起播意图达成，清掉重试状态
      this.wantPlay = false;
      this.playInFlight = false;
      this.playRetry = 0;
      this.applyKeepScreenOn(true);
      this.reportCastState(true);
      // 轨道信息要等真正解码起来才有，这里只取一次
      if (!this.tracksLoaded) {
        this.tracksLoaded = true;
        this.loadTracks();
      }
    } else if (state === 'paused') {
      this.playing = false;
      this.applyKeepScreenOn(false);
      this.showControls = true;
      this.clearHideTimer();
      this.reportCastState(false);
    } else if (state === 'completed') {
      // 播完立刻落一条「已看完」：标记本集已看 + 下次进来从头播
      this.reachedEnd = true;
      this.playing = false;
      this.applyKeepScreenOn(false);
      this.showControls = true;
      this.clearHideTimer();
      this.reportCastState(false);
      Log.i(TAG, 'play completed');
      // 先落盘再连播：切换集时 saveProgress 读的是 curEpisode，顺序反了就会把「已看」标到新集上
      this.saveProgress().then(() => {
        this.handleEpisodeEnd();
      }).catch((e: Error) => {
        Log.w(TAG, `saveProgress on completed failed: ${e}`);
        this.handleEpisodeEnd();
      });
    } else if (state === 'error') {
      this.playing = false;
      this.applyKeepScreenOn(false);
      this.showControls = true;
      this.statusText = `播放器错误${this.lastError.length > 0 ? ' ' + this.lastError : ''}`;
      this.scheduleReconnect();
    }
  }

  private togglePlay(): void {
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player === undefined) {
      this.playCurrent();
      return;
    }
    if (player.state === 'playing') {
      this.safe(() => player.pause(), 'pause');
    } else if (player.state === 'paused') {
      this.safe(() => player.play(), 'play');
    } else if (player.state === 'prepared' || player.state === 'completed') {
      this.safe(() => player.play(), 'play');
    }
    this.scheduleHideControls();
  }

  private doSeek(sec: number): void {
    const player: media.AVPlayer | undefined = this.avPlayer;
    this.previewSeeking = false;
    this.showControls = true;
    if (player === undefined) {
      return;
    }
    const ms: number = Math.floor(sec) * 1000;
    // seek() 是同步 void 接口，真正的落点由 'seekDone' / 'timeUpdate' 事件回传
    player.seek(ms);
    this.positionSec = Math.floor(sec);
    this.scheduleHideControls();
  }

  /* ==================== 长按倍速 ==================== */

  /** 长按画面 → 临时 2x 快进（松手还原），和各家手机播放器一致 */
  private startLongPressSpeed(): void {
    if (this.avPlayer === undefined) {
      return;
    }
    this.speedBeforeLongPress = this.speed;
    this.changeSpeed(2.0);
    // 长按期间把控制层收起来，别挡着画面
    this.showControls = false;
    this.clearHideTimer();
    Log.i(TAG, 'long press -> 2.0x');
  }

  private endLongPressSpeed(): void {
    if (this.avPlayer === undefined) {
      return;
    }
    this.changeSpeed(this.speedBeforeLongPress);
    Log.i(TAG, `long press end -> ${this.speedBeforeLongPress}x`);
  }

  /* ==================== 音量 ==================== */

  /**
   * 音量手势。
   *
   * ⚠️ 早先这里调的是 `AVPlayer.setVolume(v)` —— 那只是音频流的**相对**音量，
   * 基准是系统音量：系统音量关到 0 时它调到 1 也没声音，而且调它的时候
   * **系统音量条纹丝不动**，用户根本感觉不到"音量被调了"。
   * 现在换成**系统媒体音量**：把手势的 0~1 换算成系统音量等级交给根节点的 VolumePanelHost
   * （改它的 volumeLevel 就是改系统音量，三方应用唯一官方途径，详见 VolumeUtil）。
   * 播放器自己的音量保持满档，避免和系统音量叠乘造成二次衰减。
   */
  private applyVolume(v: number): void {
    const level: number = VolumeUtil.levelOf(v);
    if (level === VolumeUtil.VOLUME_UNKNOWN) {
      return;
    }
    /* ⚠️ 档位没变就**不要**再下发：每下发一次系统都要跟音量 UIExtension 交互一轮，
     * 手势一次滑动会产生几十个 move，逐个下发既浪费又会把系统侧音量 UI 反复创建销毁。 */
    if (level === this.volumeLevel) {
      return;
    }
    VolumeUtil.noteLevel(level);
    this.volumeLevel = level;
  }

  /* ==================== 锁屏 / 画面比例 / 分享 / 片头尾 ==================== */

  private toggleLock(): void {
    this.locked = !this.locked;
    // 锁屏层要常驻（上面有解锁按钮），所以两种状态都把 showControls 置真
    this.showControls = true;
    if (this.locked) {
      this.clearHideTimer();
    } else {
      this.scheduleHideControls();
    }
    Log.i(TAG, `lock=${this.locked}`);
  }

  private changeAspect(mode: number): void {
    this.aspectMode = mode;
    Log.i(TAG, `aspect mode=${mode}`);
  }

  private async shareCurrent(): Promise<void> {
    const ep: string = this.epName.length > 0 ? ` ${this.epName}` : '';
    const text: string = `我在影视仓看《${this.title}》${ep}，一起看？`;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const ok: boolean = await ShareUtil.shareText(ctx, this.title, text);
      if (!ok) {
        this.toast('分享面板打开失败');
      }
    } catch (e) {
      Log.w(TAG, `share failed: ${e}`);
      this.toast('分享失败');
    }
  }

  /** 以当前位置标记片头结束点 */
  private markIntro(): void {
    this.introMark.introEndSec = this.positionSec;
    this.hasIntroMark = true;
    IntroMarkStore.save(this.vod.name, this.introMark).catch((e: Error) => {
      Log.w(TAG, `save intro failed: ${e}`);
    });
    this.refreshSkipButtons();
    this.toast(`片头结束点：${UrlUtil.formatTime(this.positionSec)}`);
  }

  /** 以当前位置标记片尾开始点 */
  private markOutro(): void {
    this.introMark.outroStartSec = this.positionSec;
    this.hasOutroMark = true;
    IntroMarkStore.save(this.vod.name, this.introMark).catch((e: Error) => {
      Log.w(TAG, `save outro failed: ${e}`);
    });
    this.refreshSkipButtons();
    this.toast(`片尾开始点：${UrlUtil.formatTime(this.positionSec)}`);
  }

  /**
   * 按当前播放位置决定「跳过片头 / 跳过片尾」按钮是否出现。
   * 片头：还在 introEndSec 之前 → 给一个「跳过片头 mm:ss」；
   * 片尾：已经到 outroStartSec 之后 → 给一个「跳过片尾（进下一集）」。
   */
  private refreshSkipButtons(): void {
    let intro: string = '';
    if (this.introMark.introEndSec > 0 && this.positionSec > 0
      && this.positionSec < this.introMark.introEndSec) {
      intro = UrlUtil.formatTime(this.introMark.introEndSec);
    }
    let outro: string = '';
    if (this.hasOutroMark && this.introMark.outroStartSec > 0
      && this.positionSec >= this.introMark.outroStartSec) {
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
   * 片头 / 片尾标记的**自动生效**。
   *
   * == 为什么要有这个（用户反馈 2026-10-12）==
   * 「已经选了跳过片头，但影片还是从 0 播」。用户标「片头结束点」的语义就是
   * **以后每次看这部片都从这儿开始**（各大 App 的通用行为），之前只弹一个
   * 「跳过片头 mm:ss」胶囊需要手点，等于标记没生效。
   *
   * 放在 `timeUpdate` 里做：那时播放器一定在播，`seek()` 一定合法。
   * 每集每条只触发一次（`introAutoSkipped` / `outroAutoSkipped` 在换集时复位）。
   */
  private applyMarks(): void {
    // ---- 片头：还在片头区间内 → 直接跳到标记的结束点 ----
    if (!this.introAutoSkipped && this.introMark.introEndSec > 0
      && this.positionSec < this.introMark.introEndSec) {
      this.introAutoSkipped = true;
      const to: number = this.introMark.introEndSec;
      Log.i(TAG, `auto skip intro ${this.positionSec}s -> ${to}s`);
      this.toast(`已跳过片头 ${UrlUtil.formatTime(to)}`);
      // 这里在 timeUpdate 回调里，异常抛出去会打断整个回调，包一层
      try {
        this.doSeek(to);
      } catch (e) {
        const err = e as BusinessError;
        Log.w(TAG, `auto skip intro failed ${err.code}`);
      }
      return;
    }
    // ---- 片尾：到达标记的起始点 → 有下一集就自动进下一集 ----
    if (!this.outroAutoSkipped && this.hasOutroMark && this.introMark.outroStartSec > 0
      && this.positionSec >= this.introMark.outroStartSec) {
      const eps: EpisodeModel[] = this.currentEpisodes();
      if (!this.autoNext || this.curEpisode + 1 >= eps.length) {
        // 关掉连播、或已经是最后一集：把判断留着（集数/开关可能变），交给「跳过片尾」胶囊
        return;
      }
      this.outroAutoSkipped = true;
      Log.i(TAG, `auto skip outro at ${this.positionSec}s -> ep ${this.curEpisode + 1}`);
      this.toast('已跳过片尾，播放下一集');
      this.switchTo(this.curSource, this.curEpisode + 1);
    }
  }

  private changeSpeed(v: number): void {
    this.speed = v;
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player === undefined) {
      return;
    }
    // API 22: setSpeed 接收 PlaybackSpeed 枚举；按倍率设置用 setPlaybackRate(number)
    try {
      player.setPlaybackRate(v);
      Log.i(TAG, `playbackRate=${v}`);
    } catch (e) {
      const err = e as BusinessError;
      Log.e(TAG, `setPlaybackRate failed: ${err.code} ${err.message}`);
      this.statusText = '当前视频不支持该倍速';
      this.toast('当前视频不支持该倍速');
    }
  }

  private toggleControls(): void {
    // 锁屏时单击不改变任何状态：解锁按钮必须一直留着
    if (this.locked) {
      return;
    }
    this.showControls = !this.showControls;
    if (this.showControls) {
      this.scheduleHideControls();
    } else {
      this.clearHideTimer();
    }
  }

  private scheduleHideControls(): void {
    this.clearHideTimer();
    if (this.statusText.length > 0 || this.locked) {
      return;
    }
    this.hideTimer = setTimeout(() => {
      if (this.playing && !this.locked) {
        this.showControls = false;
      }
    }, HIDE_DELAY_MS);
  }

  private clearHideTimer(): void {
    if (this.hideTimer !== -1) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  /* ==================== 选集 / 线路 ==================== */

  private switchTo(sourceIndex: number, episodeIndex: number): void {
    if (sourceIndex < 0 || sourceIndex >= this.sources.length) {
      return;
    }
    const eps: EpisodeModel[] = this.sources[sourceIndex].episodes;
    if (eps.length === 0) {
      return;
    }
    if (episodeIndex < 0 || episodeIndex >= eps.length) {
      // 越界：说明这一线路播完了
      this.statusText = '已经是最后一集';
      this.showControls = true;
      return;
    }
    this.clearResumeGuard();
    this.clearHintTimer();
    this.clearUpNext();
    this.pendingResumeMs = 0;
    // 换集/换线路后轨道会变，重新探测
    this.tracksLoaded = false;
    this.audioTracks = [];
    this.subtitleTracks = [];
    this.curAudioIndex = -1;
    this.curSubIndex = -1;
    this.hasTracks = false;
    this.saveProgress();
    this.curSource = sourceIndex;
    this.curEpisode = episodeIndex;
    this.initialPositionMs = 0;
    this.previewSeeking = false;
    // 换集后缓冲进度从零开始（bufferingUpdate 只有「变大」才更新，不清会被上一集的值顶住）
    this.bufferedSec = 0;
    this.skipIntroText = '';
    this.skipOutroText = '';
    this.syncEpisodeState();
    this.buildEpisodeDialog();
    this.showControls = true;
    this.playCurrent();
  }

  private async buildEpisodeDialog(): Promise<void> {
    const ctrl: CustomDialogController = new CustomDialogController({
      builder: EpisodeDialog({
        sources: this.sources,
        currentSource: this.curSource,
        currentEpisode: this.curEpisode,
        watchedMask: this.watchedMask,
        onPick: (s: number, e: number) => {
          this.switchTo(s, e);
        },
        onClose: () => {
          this.dialogCtrl?.close();
        }
      }),
      autoCancel: true,
      // 选集面板从**右侧**滑出（贴右边缘、占满高度），不再是底部弹窗
      alignment: DialogAlignment.CenterEnd,
      // 视频还在播，别用太黑的遮罩把画面盖死
      maskColor: 'rgba(0,0,0,0.35)',
      customStyle: true
    });
    this.dialogCtrl = ctrl;
  }

  private openEpisodeDialog(): void {
    if (this.sources.length === 0) {
      return;
    }
    this.showControls = true;
    this.clearHideTimer();
    if (this.dialogCtrl === undefined) {
      this.buildEpisodeDialog();
    }
    this.dialogCtrl?.open();
    // 弹窗打开期间不要自动隐藏控制栏
    setTimeout(() => {
      this.scheduleHideControls();
    }, 800);
  }

  /* ==================== 全屏 / 屏幕方向 ==================== */

  private toggleFullscreen(): void {
    this.isFullscreen = !this.isFullscreen;
    this.applyLandscape(this.isFullscreen);
  }

  private enterLandscape(): void {
    this.applyLandscape(true);
  }

  private exitLandscape(): void {
    this.applyLandscape(false);
  }

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
    } catch (e) {
      Log.w(TAG, `applyLandscape(${land}) failed: ${e}`);
    }
  }

  /**
   * 播放中保持屏幕常亮 —— 否则全屏横屏看着看着就到系统锁屏时间自动息屏了。
   * 「是否真需要下发」的判断统一放在 ScreenUtil（详情页小窗和这里共用一个窗口）。
   */
  private applyKeepScreenOn(on: boolean): void {
    ScreenUtil.setKeepScreenOn(this.getUIContext(), on, 'player');
  }

  /* ==================== 嗅探兜底 ==================== */

  private gotoSniffer(target: string): void {
    const p: SnifferParams = new SnifferParams();
    p.targetUrl = target;
    p.referer = this.site !== undefined && this.site.api !== undefined ? this.site.api : '';
    this.getUIContext().getRouter().pushUrl({ url: 'features/detail/view/SnifferPage', params: p }).catch(() => {
      this.statusText = '解析失败，且无法启动嗅探';
      this.showControls = true;
    });
  }

  /* ==================== 杂项 ==================== */

  private syncEpisodeState(): void {
    const eps: EpisodeModel[] = this.currentEpisodes();
    this.epCount = eps.length;
    this.epIndex = this.curEpisode;
    if (this.curEpisode >= 0 && this.curEpisode < eps.length) {
      this.epName = eps[this.curEpisode].name;
    } else {
      this.epName = '';
    }
    if (this.curSource >= 0 && this.curSource < this.sources.length) {
      this.sourceName = this.sources[this.curSource].name;
      this.quality = VideoPlayerPage.qualityOf(this.sourceName);
    } else {
      this.sourceName = '';
      this.quality = '';
    }
  }

  private currentEpisodes(): EpisodeModel[] {
    if (this.curSource >= 0 && this.curSource < this.sources.length) {
      return this.sources[this.curSource].episodes;
    }
    return [];
  }

  /**
   * 落盘播放进度。
   * 用 mergeHistory 而不是 saveHistory：本集看完只是位图多一位，
   * 覆盖式写入会把之前看完的集全抹掉，「已看 X/N 集」就废了。
   */
  private saveProgress(): Promise<void> {
    if (this.vod.id.length === 0) {
      return Promise.resolve();
    }
    const eps: EpisodeModel[] = this.currentEpisodes();
    const durMs: number = this.durationSec > 0 ? this.durationSec * 1000 : 0;
    const posMs: number = this.savedPositionMs > 0 ? Math.floor(this.savedPositionMs) : 0;
    // 「已看完」判定：播放器报过 completed 为准，时长兜底只认片尾 8 秒内
    const finished: boolean = this.reachedEnd
      || (durMs > 0 && posMs > 0 && posMs >= durMs - 8000);

    const rec: PlayRecord = new PlayRecord();
    rec.siteKey = this.vod.siteKey;
    rec.vodId = this.vod.id;
    rec.vodName = this.vod.name;
    rec.pic = this.vod.pic;
    rec.sourceIndex = this.curSource;
    rec.sourceName = this.sourceName;
    rec.episodeIndex = this.curEpisode;
    rec.episodeName = (this.curEpisode >= 0 && this.curEpisode < eps.length) ? eps[this.curEpisode].name : '';
    rec.positionMs = posMs;
    rec.durationMs = durMs;
    rec.finished = finished;
    rec.totalEpisodes = eps.length;
    rec.watchedMask = this.watchedMask;
    if (finished) {
      rec.markWatched(this.curEpisode);
      // 内存镜像同步：集列表打标、以及后续 merge 都依赖它
      this.watchedMask = rec.watchedMask;
    }
    rec.updatedAt = Date.now();
    return PlayDataStore.mergeHistory(rec).catch((e: Error) => {
      Log.w(TAG, `saveProgress failed: ${e}`);
    });
  }

  private releasePlayer(): void {
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player === undefined) {
      return;
    }
    this.avPlayer = undefined;
    player.release().then(() => {
      Log.i(TAG, 'player released');
    }).catch((e: BusinessError) => {
      Log.w(TAG, `release failed ${e.code}`);
    });
  }

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  /**
   * 包装 AVPlayer 的 action，把「Promise 拒绝」和「同步抛出」一起吃掉。
   *
   * 必须传函数而不是 Promise：`player.pause()` 在状态不匹配时会「同步」抛 BusinessError，
   * 若先求值再传进 safe()，异常在进入函数前就已经抛到事件回调里了，safe 根本接不住。
   */
  private safe(run: () => Promise<void>, what: string): void {
    try {
      run().then(() => {
        Log.d(TAG, `${what} ok`);
      }).catch((e: BusinessError) => {
        Log.e(TAG, `${what} failed: ${e.code} ${e.message}`);
      });
    } catch (e) {
      const err = e as BusinessError;
      Log.e(TAG, `${what} threw: ${err.code} ${err.message}`);
    }
  }

  /**
   * `prepare()` 包一层并返回「有没有成功下发」。
   * 返回 false 时调用方不要清 `pendingPrepare` —— 表面稍后到齐了还能再补一次。
   */
  private safePrepare(player: media.AVPlayer): boolean {
    try {
      player.prepare().then(() => {
        Log.d(TAG, 'prepare ok');
      }).catch((e: BusinessError) => {
        Log.e(TAG, `prepare failed ${e.code} ${e.message}`);
      });
      return true;
    } catch (e) {
      const err = e as BusinessError;
      Log.e(TAG, `prepare threw ${err.code} ${err.message}`);
      return false;
    }
  }

  /** 竖屏模式下视频画面按 16:9 占位 */
  /**
   * 画面在视频区里按当前比例模式摆放后的宽度（vp）。
   * 尺寸还没测出来（刚进页面 / 还没收到 videoSizeChange）时先铺满，
   * 拿到真实比例后会立刻纠正成带黑边的等比尺寸。
   */
  private renderW(): Length {
    if (this.videoAreaW <= 0 || this.videoAreaH <= 0) {
      return '100%';
    }
    const r: number = this.videoRatio();
    const box: number = this.videoAreaW / this.videoAreaH;
    if (this.aspectMode === ASPECT_FILL) {
      // 铺满：短边顶满，长边溢出后被容器裁掉
      return r >= box ? this.videoAreaH * r : this.videoAreaW;
    }
    return r >= box ? this.videoAreaW : this.videoAreaH * r;
  }

  /** renderW 的配套高度 */
  private renderH(): Length {
    if (this.videoAreaW <= 0 || this.videoAreaH <= 0) {
      return '100%';
    }
    const r: number = this.videoRatio();
    const box: number = this.videoAreaW / this.videoAreaH;
    if (this.aspectMode === ASPECT_FILL) {
      return r >= box ? this.videoAreaH : this.videoAreaW / r;
    }
    return r >= box ? this.videoAreaW / r : this.videoAreaH;
  }

  /**
   * 当前生效的宽高比（宽 / 高）。
   * 16:9 / 4:3 是「强制」比例（老片用 4:3 看、宽银幕用 16:9 看）；
   * 默认 / 铺满用片源真实比例，未知时按 16:9 兜底。
   */
  private videoRatio(): number {
    if (this.aspectMode === ASPECT_16_9) {
      return 16 / 9;
    }
    if (this.aspectMode === ASPECT_4_3) {
      return 4 / 3;
    }
    if (this.videoW > 0 && this.videoH > 0) {
      return this.videoW / this.videoH;
    }
    return 16 / 9;
  }

  /**
   * 竖屏时视频区的高度。
   * 按真实比例占位：4:3 的老片就比 16:9 高一截，硬套 16:9 会平白多出一圈黑边。
   * 再高也不超过屏幕的 62%，免得竖屏短剧把下面的选集列表整个挤出屏幕外面。
   */
  private videoBoxHeight(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const wVp: number = this.getUIContext().px2vp(d.width);
      const hVp: number = this.getUIContext().px2vp(d.height);
      let h: number = wVp / this.videoRatio();
      const cap: number = hVp * 0.62;
      if (h > cap) {
        h = cap;
      }
      return Math.floor(h);
    } catch (e) {
      return 220;
    }
  }
}

/** 找不到站点时给解析器一个占位站点（解析器要求 site 必填） */
class PlaceholderSite {
  static readonly placeholder: SiteModel = {
    key: '__none__',
    name: '未知来源',
    type: 1,
    api: ''
  };
}
