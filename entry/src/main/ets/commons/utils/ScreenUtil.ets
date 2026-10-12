import { UIContext, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './LogUtil';

const TAG = 'ScreenUtil';

/**
 * 屏幕常亮。
 *
 * ⚠️ 视频播放时画面在刷新**并不能**阻止系统按锁屏时间息屏 —— 手机播着播着就黑屏，
 * 就是少了这一步显式 request。播放中 setKeepScreenOn(true)，暂停/播完/退出页面再交还系统。
 *
 * 状态是**全局共享**的：详情页小窗和横屏播放页共用一个窗口，各自记一份会互相覆盖，
 * 所以统一放在这里做「只有真变化才下发」的判断。
 */
export class ScreenUtil {
  private static keepOn: boolean = false;

  static setKeepScreenOn(ui: UIContext, on: boolean, tag: string): void {
    if (ScreenUtil.keepOn === on) {
      return;
    }
    ScreenUtil.keepOn = on;
    try {
      const ctx = ui.getHostContext() as common.UIAbilityContext;
      window.getLastWindow(ctx).then((win: window.Window) => {
        win.setWindowKeepScreenOn(on).catch((e: BusinessError) => {
          Log.w(TAG, `${tag} keepScreenOn(${on}) failed: ${e.code}`);
        });
      }).catch((e: BusinessError) => {
        Log.w(TAG, `${tag} keepScreenOn getWindow failed: ${e.code}`);
      });
    } catch (e) {
      Log.w(TAG, `${tag} keepScreenOn threw: ${e}`);
    }
  }
}
