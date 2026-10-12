/*
 * 系统媒体音量工具。
 *
 * 为什么不用 `AVPlayer.setVolume()`：
 *   它调的是**音频流自己的相对音量**（0~1 倍），基准是系统音量 ——
 *   也就是说把系统音量关到 0，`setVolume(1)` 也一样没声音；
 *   而且调它的时候**系统音量条纹丝不动**，用户根本没有"音量被调节了"的反馈。
 *
 * 为什么不用 `AudioVolumeManager.setVolume()`：
 *   那个是 System API，三方应用调用会拿到 `801 Unsupported API`，
 *   声明权限也没用（不是权限问题，是能力不对三方开放）。
 *
 * 官方给三方应用的唯一途径是 **`AVVolumePanel` 组件**：
 *   它渲染出来就是系统音量面板；改它的 `volumeLevel` 等于设置系统媒体音量，
 *   用户操作时系统会显示音量提示 UI。本文件负责把「音量等级（0~15）」和
 *   「手势用的 0~1 比例」互相换算，并读系统音量作为手势起手基准。
 *
 * 页面侧用法：
 *   `@State volumeLevel: number`（系统等级）交给**根节点常驻的 `VolumePanelHost`**
 *   （`commons/component/VolumePanelHost.ets` —— AVVolumePanel 只许出现在那里）；
 *   手势回调给的是 0~1，用 `VolumeUtil.levelOf(v)` 换成等级再赋值即可。
 */
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'VolumeUtil';

export class VolumeUtil {
  /** 音量流类型：影视播放用 MUSIC（MEDIA 流，和视频类应用一致） */
  private static readonly STREAM: audio.StreamUsage = audio.StreamUsage.STREAM_USAGE_MUSIC;
  /** 系统音量等级范围（一般 0~15），没读到就用这个兜底 */
  private static minLevel: number = 0;
  private static maxLevel: number = 15;
  /** 最近一次读到的系统等级 */
  private static level: number = 0;
  /** 是否成功读到过设备音量范围。没读到就绝不下发音量值（见 levelOf 的 -1 说明） */
  private static valid: boolean = false;
  private static inited: boolean = false;

  /**
   * 无效音量值：交给 AVVolumePanel 会被丢弃（超出设备允许范围）。
   * ⚠️ 这个常量很重要 —— `volumeLevel` 的**默认值 0 是合法音量**（静音）！
   * 页面刚建、还没读过系统音量时若传 0，等于一进播放器就把用户音量清零。
   * 所以所有「还不知道音量」的场合一律用 VOLUME_UNKNOWN，让系统忽略这次设置。
   */
  static readonly VOLUME_UNKNOWN: number = -1;

  /** 读一次系统音量等级范围。幂等，失败不抛。 */
  static ensureInit(): void {
    if (VolumeUtil.inited) {
      return;
    }
    try {
      const vm: audio.AudioVolumeManager = audio.getAudioManager().getVolumeManager();
      VolumeUtil.minLevel = vm.getMinVolumeByStream(VolumeUtil.STREAM);
      VolumeUtil.maxLevel = vm.getMaxVolumeByStream(VolumeUtil.STREAM);
      VolumeUtil.level = vm.getVolumeByStream(VolumeUtil.STREAM);
      VolumeUtil.inited = true;
      VolumeUtil.valid = true;
      hilog.info(0x0000, TAG, 'volume range %{public}d~%{public}d current=%{public}d',
        VolumeUtil.minLevel, VolumeUtil.maxLevel, VolumeUtil.level);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'read volume failed, volume gesture disabled');
    }
  }

  /** 重新从系统读一次当前等级（用户按了硬件音量键之后要同步，否则手势起手基准是旧的） */
  static syncFromSystem(): void {
    VolumeUtil.ensureInit();
    if (!VolumeUtil.valid) {
      return;
    }
    try {
      const vm: audio.AudioVolumeManager = audio.getAudioManager().getVolumeManager();
      VolumeUtil.level = vm.getVolumeByStream(VolumeUtil.STREAM);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'sync volume failed');
    }
  }

  /** 当前系统音量等级；读不到时返回 VOLUME_UNKNOWN（负值，会被系统丢弃） */
  static currentLevel(): number {
    VolumeUtil.ensureInit();
    return VolumeUtil.valid ? VolumeUtil.level : VolumeUtil.VOLUME_UNKNOWN;
  }

  /** 当前系统音量归一成 0~1（手势层的起手值 / 提示百分比用） */
  static ratio(): number {
    VolumeUtil.ensureInit();
    if (!VolumeUtil.valid) {
      return 1;
    }
    const span: number = VolumeUtil.maxLevel - VolumeUtil.minLevel;
    if (span <= 0) {
      return 1;
    }
    return VolumeUtil.clamp01((VolumeUtil.level - VolumeUtil.minLevel) / span);
  }

  /**
   * 0~1 比例 → 系统音量等级（夹在设备允许范围内）。
   * 没读到过设备范围时返回 VOLUME_UNKNOWN：宁可这次手势无效，
   * 也不能拿一个瞎猜的等级去改用户音量。
   */
  static levelOf(value: number): number {
    VolumeUtil.ensureInit();
    if (!VolumeUtil.valid) {
      return VolumeUtil.VOLUME_UNKNOWN;
    }
    const r: number = VolumeUtil.clamp01(value);
    const raw: number = VolumeUtil.minLevel + r * (VolumeUtil.maxLevel - VolumeUtil.minLevel);
    let lv: number = Math.round(raw);
    if (lv < VolumeUtil.minLevel) {
      lv = VolumeUtil.minLevel;
    }
    if (lv > VolumeUtil.maxLevel) {
      lv = VolumeUtil.maxLevel;
    }
    return lv;
  }

  /** 记下外部设置后的等级（下次 ratio() 才不会读到旧值） */
  static noteLevel(level: number): void {
    if (level >= VolumeUtil.minLevel) {
      VolumeUtil.level = level;
      VolumeUtil.valid = true;
    }
  }

  /** 0~1 静音判定用的阈值（等级最低时手势显示 0%） */
  static isMuted(): boolean {
    VolumeUtil.ensureInit();
    return VolumeUtil.valid && VolumeUtil.level <= VolumeUtil.minLevel;
  }

  private static clamp01(v: number): number {
    if (v < 0) {
      return 0;
    }
    if (v > 1) {
      return 1;
    }
    return v;
  }
}
