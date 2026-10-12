import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Store } from '../commons/utils/StoreUtil';
import { AppLifecycleUtil } from '../commons/utils/AppLifecycleUtil';

const DOMAIN = 0x0000;
const TAG = 'VideoHub';

/**
 * 应用入口 Ability
 *
 * 沉浸式说明:
 *   影视类 App 需要视频画面铺满屏幕。做法:
 *   ① setWindowLayoutFullScreen(true) 让页面从屏幕最上/最下边缘开始绘制;
 *   ② 状态栏 / 导航条背景设为透明, 由页面自身底色透上来;
 *   ③ 把状态栏 / 底部导航条高度(px)写入 AppStorage, 页面按需 px2vp 后做内边距避让;
 *   ④ 监听安全区变化(旋转/切换导航方式)实时同步 —— 播放页横屏时尤其重要。
 */
export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined;
  private avoidListener: ((data: window.AvoidAreaOptions) => void) | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setColorMode failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    // 在这里初始化 preferences：this.context 是 100% 可用的 UIAbilityContext，
    // 比页面里 getUIContext().getHostContext() 更稳（页面侧可能拿到 undefined）
    Store.init(this.context).then(() => {
      hilog.info(DOMAIN, TAG, 'preferences ready');
    }).catch((e: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'Store.init failed: %{public}s', JSON.stringify(e));
    });
    // 应用前后台总线：越早绑越好，播放页/详情页起来之前就能收到状态
    AppLifecycleUtil.init(this.context);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      this.mainWindow = win;
      this.enableImmersive(win);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'enableImmersive failed: %{public}s', JSON.stringify(err));
    }

    windowStage.loadContent('products/default/pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, '%{public}s', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    if (this.mainWindow !== undefined && this.avoidListener !== undefined) {
      try {
        this.mainWindow.off('avoidAreaChange', this.avoidListener);
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'off avoidAreaChange failed: %{public}s', JSON.stringify(err));
      }
    }
    this.avoidListener = undefined;
    this.mainWindow = undefined;
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }

  private enableImmersive(win: window.Window): void {
    win.setWindowLayoutFullScreen(true).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(err));
    });
    win.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000'
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err));
    });
    // 主界面竖屏；播放页自己会切横屏（参见 VideoPlayerPage.applyLandscape）
    win.setPreferredOrientation(window.Orientation.PORTRAIT).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'setPreferredOrientation failed: %{public}s', JSON.stringify(err));
    });

    this.syncAvoidArea(win);

    const listener = (data: window.AvoidAreaOptions): void => {
      this.syncAvoidArea(win);
    };
    this.avoidListener = listener;
    win.on('avoidAreaChange', listener);
  }

  /** 读取状态栏 / 底部导航条高度(px) 写入 AppStorage，供页面避让 */
  private syncAvoidArea(win: window.Window): void {
    try {
      const top: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const bottom: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate('safeTopPx', top.topRect.height);
      AppStorage.setOrCreate('safeBottomPx', bottom.bottomRect.height);
    } catch (err) {
      AppStorage.setOrCreate('safeTopPx', 0);
      AppStorage.setOrCreate('safeBottomPx', 0);
    }
  }
}
