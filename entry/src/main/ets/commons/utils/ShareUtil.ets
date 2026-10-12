import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { Log } from './LogUtil';

const TAG = 'ShareUtil';
/** 纯文本的统一类型描述符（UTD） */
const UTD_PLAIN_TEXT = 'general.plain-text';

/**
 * 系统分享。
 *
 * 走系统分享面板（ShareKit），由用户在面板里选微信 / 朋友圈 / 微博等目标，
 * 比自己对接各家 SDK 简单得多，也不用申请额外权限。
 * 应用没装 ShareKit 能力或用户取消时会抛，统一吞掉并返回 false，让调用方兜底提示。
 */
export class ShareUtil {
  /** 分享纯文本；返回是否成功拉起面板 */
  static async shareText(ctx: common.UIAbilityContext, title: string, text: string): Promise<boolean> {
    try {
      const record: systemShare.SharedRecord = {
        utd: UTD_PLAIN_TEXT,
        content: text,
        title: title
      };
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      await controller.show(ctx, { selectionMode: systemShare.SelectionMode.SINGLE });
      Log.i(TAG, `share panel shown: ${title}`);
      return true;
    } catch (e) {
      Log.w(TAG, `share failed: ${e}`);
      return false;
    }
  }
}
