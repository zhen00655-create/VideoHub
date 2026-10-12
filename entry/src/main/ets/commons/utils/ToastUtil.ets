import { UIContext } from '@kit.ArkUI';
import { Log } from './LogUtil';

const TAG = 'ToastUtil';

/**
 * 轻提示。
 *
 * showToast 会抛 BusinessError（比如 UIContext 已失效），统一在这里吞掉，
 * 避免调用方为了一个提示再套一层 try。
 */
export class ToastUtil {
  private static readonly DURATION: number = 2200;

  static show(ctx: UIContext, msg: string): void {
    try {
      ctx.getPromptAction().showToast({ message: msg, duration: ToastUtil.DURATION });
    } catch (e) {
      Log.w(TAG, `toast failed: ${e}`);
    }
  }
}
