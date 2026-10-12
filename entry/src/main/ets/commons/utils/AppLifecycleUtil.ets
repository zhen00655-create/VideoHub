import { ApplicationStateChangeCallback, common } from '@kit.AbilityKit';
import { Log } from './LogUtil';

const TAG = 'AppLifecycle';

/**
 * 应用前后台总线。
 *
 * ⚠️ 为什么不能用组件的 `onPageShow` / `onPageHide`：
 *   那两个只认**路由跳转**（router.pushUrl / back）。按 Home 键、切到别的应用、
 *   从最近任务回来，**一个都不会触发** —— 播放器就完全不知道应用已经不在前台了。
 *   结果就是用户反馈的「切后台有时候不停播」。必须监听应用级状态变化。
 *
 * ⚠️ `ApplicationStateChangeCallback` 在 SDK 里是个**类**（不是接口），
 *   所以只能用 `extends` 派生一个桥接类，不能用对象字面量。回调本身无参，
 *   前后台用两个方法区分，不需要再读 ApplicationState 枚举。
 */
class StateBridge extends ApplicationStateChangeCallback {
  private fg: () => void;
  private bg: () => void;

  constructor(fg: () => void, bg: () => void) {
    super();
    this.fg = fg;
    this.bg = bg;
  }

  onApplicationForeground(): void {
    this.fg();
  }

  onApplicationBackground(): void {
    this.bg();
  }
}

export class AppLifecycleUtil {
  private static bridge: StateBridge | undefined = undefined;
  private static fgCbs: Array<() => void> = [];
  private static bgCbs: Array<() => void> = [];
  private static background: boolean = false;

  /** 当前是否在后台。用来做「回来时该不该恢复播放」的判断 */
  static isBackground(): boolean {
    return AppLifecycleUtil.background;
  }

  /**
   * 绑定应用状态监听。幂等，重复调用直接返回。
   * 传 UIAbilityContext 或 ApplicationContext 都行（内部统一取 applicationContext）。
   */
  static init(ctx: common.Context): void {
    if (AppLifecycleUtil.bridge !== undefined) {
      return;
    }
    try {
      const bridge: StateBridge = new StateBridge(
        () => AppLifecycleUtil.fireForeground(),
        () => AppLifecycleUtil.fireBackground()
      );
      ctx.getApplicationContext().on('applicationStateChange', bridge);
      AppLifecycleUtil.bridge = bridge;
      Log.i(TAG, 'applicationStateChange bound');
    } catch (e) {
      Log.w(TAG, `bind applicationStateChange failed: ${e}`);
    }
  }

  static onForeground(cb: () => void): void {
    if (AppLifecycleUtil.fgCbs.indexOf(cb) < 0) {
      AppLifecycleUtil.fgCbs.push(cb);
    }
  }

  static offForeground(cb: () => void): void {
    const i: number = AppLifecycleUtil.fgCbs.indexOf(cb);
    if (i >= 0) {
      AppLifecycleUtil.fgCbs.splice(i, 1);
    }
  }

  static onBackground(cb: () => void): void {
    if (AppLifecycleUtil.bgCbs.indexOf(cb) < 0) {
      AppLifecycleUtil.bgCbs.push(cb);
    }
  }

  static offBackground(cb: () => void): void {
    const i: number = AppLifecycleUtil.bgCbs.indexOf(cb);
    if (i >= 0) {
      AppLifecycleUtil.bgCbs.splice(i, 1);
    }
  }

  private static fireForeground(): void {
    AppLifecycleUtil.background = false;
    Log.i(TAG, `-> foreground, ${AppLifecycleUtil.fgCbs.length} listener(s)`);
    // 先拷一份再遍历：回调里可能会 off 自己
    const list: Array<() => void> = AppLifecycleUtil.fgCbs.slice();
    for (let i = 0; i < list.length; i++) {
      try {
        list[i]();
      } catch (e) {
        Log.w(TAG, `foreground cb failed: ${e}`);
      }
    }
  }

  private static fireBackground(): void {
    AppLifecycleUtil.background = true;
    Log.i(TAG, `-> background, ${AppLifecycleUtil.bgCbs.length} listener(s)`);
    const list: Array<() => void> = AppLifecycleUtil.bgCbs.slice();
    for (let i = 0; i < list.length; i++) {
      try {
        list[i]();
      } catch (e) {
        Log.w(TAG, `background cb failed: ${e}`);
      }
    }
  }
}
