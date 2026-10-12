/*
 * AVPlayer 的 error 事件分类。
 *
 * == 为什么需要这个文件（2026-10-12 用户日志）==
 * 现象：详情页小窗「点一下，过几秒其实能正常播」，但中间会弹一句
 *   `播放错误 5400102 Operate Not Permit: current state is not prepared/playing/paused/completed,
 *    unsupport audio interrupt operation`。
 * 日志把链条摆得很清楚：
 *   `JsSetAudioInterruptMode In` → `OnErrorCb errorCode 5400102` → `JsGetState curState: idle`
 *   →（同一毫秒）`JsCreateMediaSourceWithUrl` → initialized → prepare → prepared → playing。
 * 也就是：这条 error 是**应用自己在 idle 状态下设 `audioInterruptMode` 招来的**，
 * 播放器随后一切正常。把它当失败渲染成红字，纯属误报。
 *
 * 结论：判据不能是「有没有 error 事件」，而要看**这错误是不是纯状态机时序问题**。
 * `play()` / `seek()` / `prepare()` 在状态切换的夹缝里被拒，也都是同一个 5400102。
 */
import { media } from '@kit.MediaKit';

/** AVPlayer：当前状态不允许该操作（Operation not allowed）。状态机时序问题，媒体本身没坏。 */
export const ERR_OPERATION_NOT_ALLOWED: number = 5400102;

export class PlayerErrorUtil {
  /** 播放器当前状态是否「可播 / 已就绪」 */
  static playable(state: media.AVPlayerState): boolean {
    return state === 'playing' || state === 'prepared' || state === 'paused' || state === 'completed';
  }

  /**
   * 是否是「状态机时序抖动」——可以忽略，界面维持原样（加载中 / 播放中）。
   * 只有 `error` / `released` 才说明播放器真的趴下了。
   */
  static isTimingError(code: number, state: media.AVPlayerState): boolean {
    if (code !== ERR_OPERATION_NOT_ALLOWED) {
      return false;
    }
    return state !== 'error' && state !== 'released';
  }

  /**
   * 这个 error 事件是否可以忽略（不弹错、不中断起播流程）。
   * ① 是状态机时序抖动（5400102）；
   * ② 虽然报了错，但播放器仍处于可播状态 —— 说明它自己已经缓过来了，弹错反而是误报。
   */
  static shouldIgnore(code: number, state: media.AVPlayerState): boolean {
    return PlayerErrorUtil.isTimingError(code, state) || PlayerErrorUtil.playable(state);
  }
}
