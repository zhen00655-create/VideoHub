import { audio } from '@kit.AudioKit';
import { media } from '@kit.MediaKit';
import { Log } from './LogUtil';
import { PlayerErrorUtil } from './PlayerErrorUtil';

const TAG = 'AudioFocus';

/** 焦点事件的归一化动作（把 audio.InterruptHint 收敛成 5 个，页面只认这几个） */
export const FOCUS_NONE: number = 0;
/** 系统要求让出焦点：必须真的暂停 */
export const FOCUS_PAUSE: number = 1;
/** 焦点回来了：这是系统给的「可以继续播了」，必须接着播 */
export const FOCUS_RESUME: number = 2;
export const FOCUS_DUCK: number = 3;
export const FOCUS_UNDUCK: number = 4;

/**
 * 音频焦点（Audio Interrupt）桥。
 *
 * ⚠️ 用户反馈的「播放中声音突然消失，暂停再播一下才回来」就是这个坑：
 *   AVPlayer 默认是 `SHARE_MODE`（共享焦点），别的应用（来电、闹钟、
 *   其他播放器、短视频 App）申请焦点时，**系统会直接把你这条音频流静音**，
 *   但 **AVPlayer 自身的 state 仍然是 `playing`、时间还在走**。
 *   此时：
 *     · 不监听 audioInterrupt → 系统认为你没让出焦点，永远不会给你
 *       `INTERRUPT_HINT_RESUME`，于是这条流**一直哑着**；
 *     · 手动 pause 再 play → 重新走一遍申请焦点流程，声音就回来了。
 *   —— 症状完全吻合。
 *
 * 正确姿势（官方要求）：收到 PAUSE / STOP 就**真的 `pause()`**，
 * 系统才会在合适的时候回一个 RESUME，这时再 `play()`。
 *
 * 另外：DUCK / UNDUCK（音量压低 / 恢复）不需要做什么 —— 本应用调的是
 * **系统媒体音量**（AVVolumePanel 那条路），压低由系统自己做。
 */
export class AudioFocusUtil {
  /**
   * 给播放器挂上焦点监听。同一个 player 重复 attach 会重复注册，
   * 调用方保证只在 createAVPlayer 之后挂一次即可。
   */
  static attach(player: media.AVPlayer, onAction: (kind: number) => void): void {
    try {
      player.on('audioInterrupt', (info: audio.InterruptEvent) => {
        const kind: number = AudioFocusUtil.kindOf(info.hintType);
        Log.i(TAG, `interrupt event=${info.eventType} force=${info.forceType} hint=${info.hintType} -> ${kind}`);
        onAction(kind);
      });
    } catch (e) {
      Log.w(TAG, `attach failed: ${e}`);
    }
  }

  /**
   * 把焦点请求模式显式设成共享模式（本来是默认值，写出来防止被别处改掉）。
   *
   * ⚠️ **只能在 `prepared` / `playing` / `paused` / `completed` 下调**（2026-10-12 日志铁证）：
   * 早期在 `createAVPlayer()` 之后**立刻**赋值，那时状态还是 `idle`，原生侧直接抛一条
   *   `OnErrorCb errorCode 5400102 Operate Not Permit: current state is not
   *    prepared/playing/paused/completed, unsupport audio interrupt operation`
   * 这条 error 会被页面的 error 回调当成「播放错误」渲染出来 ——
   * 用户看到的就是「小窗提示播放错误 5400102，可点一下过几秒又能正常播」。
   * 所以：注册监听留在 attach()（随时可以注册），**设模式必须等状态合法**，
   * 调用点是两个播放页 stateChange 的 `prepared` 分支，状态不合法就静默跳过。
   */
  static applyInterruptMode(player: media.AVPlayer): void {
    if (!PlayerErrorUtil.playable(player.state)) {
      Log.i(TAG, `skip audioInterruptMode, state=${player.state}`);
      return;
    }
    try {
      player.audioInterruptMode = audio.InterruptMode.SHARE_MODE;
      Log.i(TAG, 'audioInterruptMode = SHARE_MODE');
    } catch (e) {
      Log.w(TAG, `set audioInterruptMode failed: ${e}`);
    }
  }

  /** audio.InterruptHint → 归一化动作 */
  static kindOf(hint: audio.InterruptHint): number {
    if (hint === audio.InterruptHint.INTERRUPT_HINT_PAUSE
      || hint === audio.InterruptHint.INTERRUPT_HINT_STOP
      || hint === audio.InterruptHint.INTERRUPT_HINT_MUTE) {
      return FOCUS_PAUSE;
    }
    if (hint === audio.InterruptHint.INTERRUPT_HINT_RESUME
      || hint === audio.InterruptHint.INTERRUPT_HINT_UNMUTE) {
      return FOCUS_RESUME;
    }
    if (hint === audio.InterruptHint.INTERRUPT_HINT_DUCK) {
      return FOCUS_DUCK;
    }
    if (hint === audio.InterruptHint.INTERRUPT_HINT_UNDUCK) {
      return FOCUS_UNDUCK;
    }
    return FOCUS_NONE;
  }

  /**
   * 把音频流自身的相对音量压回满档。
   *
   * 为什么需要：`AVPlayer.setVolume()` 调的是**流内相对音量**，基准是系统音量。
   * 只要有任何一条路径（历史代码、系统 duck、第三方 SDK）把它压到 0，
   * 表现就是「时长在走、画面在动，但一点声音都没有」，而且 pause/play 也不一定修得好。
   * 每次焦点回来 / 回前台都压一次满档，顺手把系统音量同步一下。
   */
  static restoreStreamVolume(player: media.AVPlayer): void {
    try {
      player.setVolume(1);
    } catch (e) {
      Log.w(TAG, `setVolume(1) failed: ${e}`);
    }
  }
}
