import { AVVolumePanel } from '@kit.AudioKit';

/**
 * 系统音量面板宿主 —— **全工程唯一允许出现 `AVVolumePanel` 的地方**。
 *
 * == 为什么要单独抽出来、还只能挂在页面根上（2026-10-12 事故）==
 *
 * `AVVolumePanel` 是三方应用改**系统媒体音量**的唯一官方途径（详见 `VolumeUtil`），
 * 但它内部是拿 `UIExtensionComponent` 去加载系统音量扩展（日志里的 `AVVolumeExtension`）。
 * 这个内部节点**自己会被触摸测试命中，而且命中之后不再往下传**，实测日志铁证：
 *
 *     ITK Id:1056447, TTHNI:fId: 0{ T: UIExtensionComponent, D: 15 };
 *     ITK Id:1056447, TTHRTI:          ← 空的：一个手势/点击识别器都没进结果树
 *
 * 症状因此是「**全画面一起失灵**」：手势层的单击/双击/长按/滑动全废，
 * 连它下面的「缩小屏幕 / 锁住」按钮也点不动 —— 用户以为是两层打架，其实是上面盖了个
 * 吃事件的系统扩展。
 *
 * == 三条铁律，改这个文件前先读 ==
 *   ① **只挂载一次**：必须挂在页面里**无条件渲染**的根容器上（视频区那个 Stack），
 *      绝不能再放进 `if (showControls)` 这种随控制条显隐反复销毁重建的分支 ——
 *      每重建一次就等于把系统音量扩展拆了重装（日志里的 `AVVolumeExtension DestroySession`），
 *      这也正是「调音量时好时坏」的来源。
 *   ② **整棵子树都不参与触摸测试**：`HitTestMode.None` 只管自己、**不管子节点**
 *      （内部那个 UIExtensionComponent 照样被命中，这就是上一版没修住的原因），
 *      必须用 `HitTestMode.BLOCK_DESCENDANTS`（API 20：自己和整棵子树都不当目标）。
 *   ③ **连布局盒一起挪出屏幕**：音量反馈由 `PlayerGestureLayer` 的中央提示负责，
 *      系统那根音量条再冒出来就重复了。注意 `volumeParameter.position` 挪的只是
 *      **面板画在哪**（SDK 原文 `Sets the position of volume panel`），它带不走内部那个
 *      扩展节点的布局盒/命中区域 —— 所以外面必须再套一层 `position`。
 */
@Component
export struct VolumePanelHost {
  /**
   * 系统媒体音量等级（0~15 那种，不是 0~1）。
   * ⚠️ 默认值必须给**负的越界值**（`VolumeUtil.VOLUME_UNKNOWN`）：
   * `volumeLevel` 的 0 是合法音量（静音），拿 0 当初始值等于一进播放器就把用户音量清零；
   * 负值会被系统丢弃（= 这次不设置）。
   */
  @Prop volumeLevel: number = -1;

  build() {
    Column() {
      AVVolumePanel({
        volumeLevel: this.volumeLevel,
        volumeParameter: { position: { x: -1, y: -1 } }
      })
        .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
    }
    // 尺寸照旧给满：面板要拿到和以前一样的布局约束，系统音量扩展才会正常建立
    .width('100%')
    .height('100%')
    // 再整个挪到屏幕外 —— 只借它「设置系统音量」的能力，不显示、也不占任何可触摸区域
    .position({ x: -4000, y: -4000 })
    .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
  }
}
