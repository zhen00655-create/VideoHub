import { common } from '@kit.AbilityKit';
import { UIContext, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './LogUtil';

const TAG = 'BrightnessUtil';

/**
 * 播放器亮度手势。
 *
 * 亮度是**窗口级**的（window.setWindowBrightness），不改系统亮度、退出即可还原，
 * 这也是普通应用唯一能做的「亮度调节」。值的范围 0~1；
 * 窗口原来的亮度可能是 -1（跟随系统），这种情况拿不到真实屏幕亮度，
 * 就用一个中间值当代替的起手点，退出时再把原值（含 -1）写回去。
 */
export class BrightnessUtil {
  /** 手势用的当前窗口亮度（0~1），进页面时由 capture() 初始化 */
  private static value: number = 0.6;
  /** 页面进入时的原值，退出时还原（-1 表示跟随系统） */
  private static original: number = -1;
  private static captured: boolean = false;

  /** 当前亮度（0~1） */
  static current(): number {
    return BrightnessUtil.value;
  }

  /**
   * 进页面时调一次：记下窗口亮度原值，同时给手势一个起手点。
   * 幂等 —— 播放页和详情页共用同一个窗口，重复调用不会互相覆盖原值。
   */
  static capture(ui: UIContext): void {
    if (BrightnessUtil.captured) {
      return;
    }
    BrightnessUtil.captured = true;
    BrightnessUtil.win(ui).then((win: window.Window) => {
      const b: number = win.getWindowProperties().brightness;
      BrightnessUtil.original = b;
      // 跟随系统时（-1）读不到真实值，用 0.6 起手
      BrightnessUtil.value = b >= 0 ? b : 0.6;
      Log.i(TAG, `capture original=${b} start=${BrightnessUtil.value}`);
    }).catch((e: BusinessError) => {
      Log.w(TAG, `capture getWindow failed ${e.code}`);
    });
  }

  /** 设置窗口亮度，入参会被夹到 [0.02, 1] —— 0 会直接黑屏，留一线 */
  static set(ui: UIContext, v: number): void {
    let b: number = v;
    if (b < 0.02) {
      b = 0.02;
    }
    if (b > 1) {
      b = 1;
    }
    BrightnessUtil.value = b;
    BrightnessUtil.win(ui).then((win: window.Window) => {
      win.setWindowBrightness(b).catch((e: BusinessError) => {
        Log.w(TAG, `set brightness failed ${e.code}`);
      });
    }).catch((e: BusinessError) => {
      Log.w(TAG, `set getWindow failed ${e.code}`);
    });
  }

  /** 退出页面时还原窗口亮度 */
  static restore(ui: UIContext): void {
    if (!BrightnessUtil.captured) {
      return;
    }
    BrightnessUtil.captured = false;
    const back: number = BrightnessUtil.original;
    BrightnessUtil.win(ui).then((win: window.Window) => {
      win.setWindowBrightness(back).catch((e: BusinessError) => {
        Log.w(TAG, `restore brightness failed ${e.code}`);
      });
    }).catch((e: BusinessError) => {
      Log.w(TAG, `restore getWindow failed ${e.code}`);
    });
  }

  private static win(ui: UIContext): Promise<window.Window> {
    const ctx = ui.getHostContext() as common.UIAbilityContext;
    return window.getLastWindow(ctx);
  }
}
