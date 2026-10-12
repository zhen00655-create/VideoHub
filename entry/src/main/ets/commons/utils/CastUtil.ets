/*
 * 投屏（投播）工具。
 *
 * == 为什么走 AVSession + AVCastPicker ==
 * HarmonyOS 把「找设备 / 连接 / 认证」全部收进系统，应用**不自己做 SSDP 发现和 SOAP 控制**。
 * 应用能拿到的只有两样：
 *   1. `AVCastPicker` 组件 —— 渲染成一个图标，点它系统弹出设备选择半模态
 *      （Cast+ 协议 + 标准 DLNA 设备都由系统扫，应用一行发现逻辑都不用写）；
 *   2. `AVCastController` —— 设备连上之后用它 prepare/start 把资源推过去。
 * 这和安卓上各家自建 DLNA 栈（或接乐播 SDK）的路子不一样：在鸿蒙上自建反而
 * 搜不到华为生态的设备，也没有系统播控中心的联动。
 *
 * == 前置条件（少一个都搜不到设备）==
 *   ① `createAVSession(ctx, tag, 'video')` 建会话；
 *   ② `setExtras({ requireAbilityList: ['url-cast'] })` **声明支持投播** ——
 *      官方明确写过：设备列表出不来先查这里；
 *   ③ `setAVMetadata(...)` 带 `filter: TYPE_CAST_PLUS_STREAM | TYPE_DLNA` ——
 *      filter 决定哪些协议的设备会被列出来；元数据没设会导致投播后远端黑屏；
 *   ④ 双端都要开蓝牙 + WiFi（系统层面的要求，应用管不了）。
 *
 * == 本端与远端的关系 ==
 *   `outputDeviceChange` 告诉我们连上了哪个设备。连上远端后由系统播控中心接管
 *   远端的播放控制，本端只需要：停止本地播放 → 把状态上报给会话（播控中心 UI 才不会脱节）。
 *   播控中心反过来下发的指令（play/pause/seek）通过会话的 on() 回调转给本地播放器。
 */
import { avSession, AVCastPickerStyle } from '@kit.AVSessionKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'CastUtil';
/** 会话 tag，同一应用内唯一即可 */
const SESSION_TAG: string = 'yingshicang_video';

/** 要投出去的这一集的信息 */
export class CastMedia {
  /** 唯一 id（换集要变，否则播控中心/远端不会认为是新资源） */
  assetId: string = '';
  title: string = '';
  subtitle: string = '';
  /** 时长（毫秒） */
  durationMs: number = 0;
  /** 直链播放地址：远端设备自己拉这个地址，所以必须是 http(s) 直链（m3u8/mp4） */
  mediaUri: string = '';

  constructor(assetId: string, title: string, subtitle: string, durationMs: number, mediaUri: string) {
    this.assetId = assetId;
    this.title = title;
    this.subtitle = subtitle;
    this.durationMs = durationMs;
    this.mediaUri = mediaUri;
  }
}

export class CastUtil {
  private static session: avSession.AVSession | null = null;
  /** 建会话是异步的，重入时要挡一下（两个页面同时进） */
  private static creating: boolean = false;
  private static ready: boolean = false;
  /** 已连上远端投播设备 */
  private static connected: boolean = false;
  private static deviceName: string = '';
  private static controller: avSession.AVCastController | null = null;
  /** 当前这一集的资源信息，投播时要用 */
  private static media: CastMedia | null = null;
  /** 主动拉起设备面板用的 helper（见 showPicker） */
  private static picker: avSession.AVCastPickerHelper | null = null;

  /* ---------- 页面挂上来的回调（不想用的直接不赋值） ---------- */
  /** 播控中心 / 远端要求播放 */
  static onRemotePlay: () => void = () => {
  };
  /** 播控中心 / 远端要求暂停 */
  static onRemotePause: () => void = () => {
  };
  /** 播控中心 / 远端要求停止 */
  static onRemoteStop: () => void = () => {
  };
  /** 播控中心要求跳转（毫秒） */
  static onRemoteSeek: (ms: number) => void = () => {
  };
  /** 投播设备连接状态变化，页面据此改按钮样式 / 提示 */
  static onDeviceChanged: (connected: boolean, deviceName: string) => void = () => {
  };

  static isReady(): boolean {
    return CastUtil.ready;
  }

  static isCasting(): boolean {
    return CastUtil.connected;
  }

  static device(): string {
    return CastUtil.deviceName;
  }

  /**
   * 拉起系统的「选择投播设备」面板（设备发现/连接/认证仍归系统，我们不自己扫）。
   *
   * == 为什么不再用 `AVCastPicker` 组件（2026-10-12 事故）==
   * 那个组件是**系统自绘**的：图标的「active（红色）」态由系统自己根据会话状态决定，
   * 应用既改不掉也解释不清。用户插上蓝牙耳机后，某些机型会把 A2DP 设备也算进投播态，
   * 于是**带着耳机也显示红色投屏图标** —— 用户明确要求「带耳机不能算投屏、图标不能红」。
   * 现在改成「自绘图标（颜色只听我们自己的 `casting`）+ `AVCastPickerHelper.select()`
   * 拉起同一个系统面板」：功能完全一样，但图标状态 100% 由应用掌握。
   */
  static async showPicker(ctx: common.UIAbilityContext): Promise<void> {
    try {
      if (CastUtil.picker === null) {
        CastUtil.picker = new avSession.AVCastPickerHelper(ctx);
      }
      await CastUtil.picker.select({
        sessionType: 'video',
        pickerStyle: AVCastPickerStyle.STYLE_PANEL
      });
      hilog.info(0x0000, TAG, 'cast picker shown');
    } catch (err) {
      hilog.error(0x0000, TAG, 'show cast picker failed');
    }
  }

  /**
   * 建会话（幂等）。返回是否可用 —— 不可用就别渲染 AVCastPicker。
   * 注意：必须在能拿到 UIAbilityContext 的地方调（页面的 getUIContext().getHostContext()）。
   */
  static async ensureSession(ctx: common.UIAbilityContext): Promise<boolean> {
    if (CastUtil.ready && CastUtil.session !== null) {
      return true;
    }
    if (CastUtil.creating) {
      return false;
    }
    CastUtil.creating = true;
    try {
      const s: avSession.AVSession = await avSession.createAVSession(ctx, SESSION_TAG, 'video');
      /* 关键一步：声明本应用支持投播。少了这句，AVCastPicker 里设备列表是空的。 */
      await s.setExtras({ requireAbilityList: ['url-cast'] });
      /* 播控中心（含远端遥控器）反向下发的指令 */
      s.on('play', () => {
        CastUtil.onRemotePlay();
      });
      s.on('pause', () => {
        CastUtil.onRemotePause();
      });
      s.on('stop', () => {
        CastUtil.onRemoteStop();
      });
      s.on('seek', (ms: number) => {
        CastUtil.onRemoteSeek(ms);
      });
      await s.activate();
      /*
       * ⚠️ `outputDeviceChange` **必须在 activate() 之后注册**（2026-10-12 日志）：
       * 注册在 activate 之前时，原生侧只回一句
       *   `[AddRegisterEvent]eventName is invalid: eventName = outputDeviceChange`
       * ——事件被静默丢弃，于是「连上投播设备」这个状态永远拿不到，自绘投屏图标也就永远不会变红。
       * 挪到 activate 之后 + try/catch：即便某个版本仍不收，也不能把整个会话创建带崩。
       */
      try {
        s.on('outputDeviceChange', (state: avSession.ConnectionState, device: avSession.OutputDeviceInfo) => {
          CastUtil.handleDeviceChange(state, device);
        });
      } catch (err) {
        hilog.error(0x0000, TAG, 'register outputDeviceChange failed');
      }
      CastUtil.session = s;
      CastUtil.ready = true;
      hilog.info(0x0000, TAG, 'av session ready');
      return true;
    } catch (err) {
      hilog.error(0x0000, TAG, 'create av session failed');
      return false;
    } finally {
      CastUtil.creating = false;
    }
  }

  /**
   * 设置当前在播的资源（起播 / 切集 / 换线路都要调）。
   * 已经在投播中时，会把新资源直接推给远端设备（实现"投屏状态下换集"）。
   */
  static async setMedia(m: CastMedia): Promise<void> {
    CastUtil.media = m;
    const s: avSession.AVSession | null = CastUtil.session;
    if (s === null) {
      return;
    }
    try {
      const meta: avSession.AVMetadata = {
        assetId: m.assetId,
        title: m.title,
        subtitle: m.subtitle,
        duration: m.durationMs,
        /* filter 决定设备列表里出现哪些协议：Cast+ Stream（华为生态）+ DLNA（第三方电视/盒子） */
        filter: avSession.ProtocolType.TYPE_CAST_PLUS_STREAM | avSession.ProtocolType.TYPE_DLNA
      };
      await s.setAVMetadata(meta);
      if (CastUtil.connected) {
        await CastUtil.pushToRemote();
      }
    } catch (err) {
      hilog.error(0x0000, TAG, 'set metadata failed');
    }
  }

  /**
   * 补发一次元数据。
   * 场景：起播比建会话快（会话是异步的），setMedia 时还没有 session，
   * 元数据只存在本地；等会话就绪后要补一次，否则播控中心是空的。
   */
  static async flushMedia(): Promise<void> {
    const m: CastMedia | null = CastUtil.media;
    if (m !== null) {
      await CastUtil.setMedia(m);
    }
  }

  /** 把本端播放状态报给会话 —— 不报的话播控中心的进度条和按钮状态会和实际不一致 */
  static async setState(playing: boolean, positionMs: number, speed: number): Promise<void> {
    const s: avSession.AVSession | null = CastUtil.session;
    if (s === null) {
      return;
    }
    try {
      const st: avSession.AVPlaybackState = {
        state: playing
          ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        speed: speed,
        /* 上报进度必须带 updateTime，否则播控中心算不准 */
        position: { elapsedTime: positionMs, updateTime: Date.now() }
      };
      await s.setAVPlaybackState(st);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'set playback state failed');
    }
  }

  /** 断开会话（页面销毁时调）。会顺便把投播停掉。 */
  static async release(): Promise<void> {
    const s: avSession.AVSession | null = CastUtil.session;
    CastUtil.session = null;
    CastUtil.controller = null;
    CastUtil.picker = null;
    CastUtil.ready = false;
    CastUtil.connected = false;
    CastUtil.deviceName = '';
    CastUtil.media = null;
    if (s === null) {
      return;
    }
    try {
      await s.stopCasting();
    } catch (err) {
      /* 本来就没在投播，忽略 */
    }
    try {
      await s.deactivate();
      await s.destroy();
      hilog.info(0x0000, TAG, 'av session released');
    } catch (err) {
      hilog.warn(0x0000, TAG, 'release av session failed');
    }
  }

  /* ==================== 内部 ==================== */

  /**
   * 耳机特征词（小写）。
   * 蓝牙/有线耳机的名字千奇百怪（「HUAWEI FreeBuds 6」「WH-1000XM5」「XX 的 AirPods」…），
   * 设备类型兜不住时再拿名字兜最后一道。
   * ⚠️ **千万别把「音箱」写进来** —— 智能音箱是合法投播目标（Cast+ smart speaker），
   * 拉黑它会让人投不了音箱。
   */
  private static readonly HEADSET_KEYS: string[] = [
    '耳机', '听筒', '耳麦', 'headset', 'headphone', 'earphone', 'earbud', 'buds', 'airpod'
  ];

  /**
   * 这个设备是不是「本机音频输出」—— 内置扬声器 / 听筒 / 有线耳机 / 蓝牙耳机 / 蓝牙音箱 / 车机。
   *
   * == 为什么必须单独判（2026-10-12 事故）==
   * 插个耳机，`outputDeviceChange` 一样会回调。早期版本只看 `castCategory` 一个判据，
   * 而部分机型会把蓝牙 A2DP 设备报成「远端」，于是应用**误以为自己投屏了**：
   * 弹「已投屏到「XXX 耳机」」→ 把本机播放暂停 → 还去 `getAVCastController()`
   * `prepare()/start()` 推流。之后音量手势就和系统投播音量面板打架，
   * 表现为「声音调节时好时坏、偶发无声」。
   * **耳机只是换了个出声的地方，不属于投屏功能范畴。**
   *
   * 四条判据任一命中即认定为本机音频设备（宁可漏判一个冷门投播设备，
   * 也绝不能把耳机误判成投屏）：
   *   ① 系统明说这是本机路由（内置扬声器 / 音频插孔 / A2DP）；
   *   ② 设备类型是本机或蓝牙；
   *   ③ 设备声明的协议里既没有 Cast+ 也没有 DLNA —— 拉不走画面，只能是音频设备；
   *   ④ 名字里带耳机特征词。
   */
  private static isLocalAudioRoute(d: avSession.DeviceInfo): boolean {
    /* ① 系统自己的归类：CATEGORY_LOCAL 的官方定义就含「A2DP 设备」 */
    if (d.castCategory === avSession.AVCastCategory.CATEGORY_LOCAL) {
      return true;
    }
    /* ② 设备类型：本机 / 蓝牙 —— 蓝牙音箱、蓝牙耳机、车机都只是音频路由 */
    if (d.deviceType === avSession.DeviceType.DEVICE_TYPE_LOCAL ||
      d.deviceType === avSession.DeviceType.DEVICE_TYPE_BLUETOOTH) {
      return true;
    }
    /* ③ 协议：真投播设备必带 Cast+ Stream 或 DLNA；协议位存在且不含投播位 → 纯音频设备。
          协议位取不到（undefined）或为 0 时不据此否掉，交给其它判据。 */
    const proto: number | undefined = d.supportedProtocols;
    if (proto !== undefined && proto !== 0) {
      const castBits: number =
        avSession.ProtocolType.TYPE_CAST_PLUS_STREAM | avSession.ProtocolType.TYPE_DLNA;
      if ((proto & castBits) === 0) {
        return true;
      }
    }
    /* ④ 名字兜底 */
    const n: string = (d.deviceName === undefined || d.deviceName === null)
      ? '' : d.deviceName.toLowerCase();
    if (n.length > 0) {
      for (let i = 0; i < CastUtil.HEADSET_KEYS.length; i++) {
        if (n.indexOf(CastUtil.HEADSET_KEYS[i]) >= 0) {
          return true;
        }
      }
    }
    return false;
  }

  private static handleDeviceChange(state: avSession.ConnectionState,
    device: avSession.OutputDeviceInfo): void {
    const list: Array<avSession.DeviceInfo> = device.devices;
    const first: avSession.DeviceInfo | null =
      (list !== undefined && list !== null && list.length > 0) ? list[0] : null;
    if (first === null) {
      /* 没有设备信息时只认「明确断开」这一种信号，别乱清状态 */
      if (state === avSession.ConnectionState.STATE_DISCONNECTED) {
        CastUtil.markDisconnected();
      }
      return;
    }
    /* 这条日志是排查投屏误判的关键：能直接看到系统把该设备归成了什么 */
    const proto: number = (first.supportedProtocols === undefined) ? -1 : first.supportedProtocols;
    hilog.info(0x0000, TAG,
      'outputDevice state=%{public}d name=%{public}s type=%{public}d category=%{public}d proto=%{public}d',
      state, first.deviceName, first.deviceType, first.castCategory, proto);

    /*
     * ⚠️ 耳机 / 扬声器这类本机音频输出**直接忽略**：
     * 既不置为「投屏中」，也不清除已有投屏状态（断开由系统单独的 DISCONNECTED 事件负责）。
     */
    if (CastUtil.isLocalAudioRoute(first)) {
      hilog.info(0x0000, TAG, 'output device is local audio route, not a cast: %{public}s',
        first.deviceName);
      return;
    }

    if (state === avSession.ConnectionState.STATE_CONNECTED) {
      CastUtil.connected = true;
      CastUtil.deviceName = first.deviceName;
      hilog.info(0x0000, TAG, 'cast connected: %{public}s', first.deviceName);
      CastUtil.pushToRemote();
      CastUtil.onDeviceChanged(true, first.deviceName);
    } else if (state === avSession.ConnectionState.STATE_DISCONNECTED) {
      CastUtil.markDisconnected();
    }
  }

  /** 统一收口「投播断开」：复位状态 + 通知页面（本来就没投时静默，避免开机弹「投屏已断开」） */
  private static markDisconnected(): void {
    if (!CastUtil.connected) {
      return;
    }
    CastUtil.connected = false;
    CastUtil.deviceName = '';
    CastUtil.controller = null;
    hilog.info(0x0000, TAG, 'cast disconnected');
    CastUtil.onDeviceChanged(false, '');
  }

  /** 把当前资源推给远端设备并起播 */
  private static async pushToRemote(): Promise<void> {
    const s: avSession.AVSession | null = CastUtil.session;
    const m: CastMedia | null = CastUtil.media;
    if (s === null || m === null || m.mediaUri.length === 0) {
      return;
    }
    try {
      const item: avSession.AVQueueItem = {
        itemId: 0,
        description: {
          assetId: m.assetId,
          title: m.title,
          subtitle: m.subtitle,
          mediaUri: m.mediaUri,
          duration: m.durationMs
        }
      };
      await s.setAVQueueItems([item]);
      const c: avSession.AVCastController = await s.getAVCastController();
      CastUtil.controller = c;
      await c.prepare(item);
      await c.start(item);
      hilog.info(0x0000, TAG, 'pushed to remote: %{public}s', m.mediaUri);
    } catch (err) {
      hilog.error(0x0000, TAG, 'push to remote failed');
    }
  }
}
