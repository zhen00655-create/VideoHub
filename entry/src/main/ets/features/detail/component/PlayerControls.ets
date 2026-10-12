import { AppTheme } from '../../../commons/theme/AppTheme';
import { UrlUtil } from '../../../commons/utils/UrlUtil';

/** 画面比例模式 */
export const ASPECT_FIT: number = 0;
export const ASPECT_FILL: number = 1;
export const ASPECT_16_9: number = 2;
export const ASPECT_4_3: number = 3;

/** 底部弹出的选择面板种类 */
const POPUP_NONE: number = 0;
const POPUP_SPEED: number = 1;
const POPUP_ASPECT: number = 2;

/*
 * 尺寸统一放这里。
 *
 * 图标一律走 `resources/base/media/player_ic_*.svg` + `Image`（见 build 里的 iconImg）。
 * SVG 的内容包围盒约占 viewBox 的 75%~80%，所以「可见高度 ≈ size × 0.78」。
 * 判据：**图标可见高度 ÷ 圆直径 ≈ 50%~55%**，低于 40% 就会显得"圈大图标小"。
 * 现在 44 + 30 → 可见 ≈23vp ≈ 圆的 53%。
 */
/** 右侧竖排圆按钮直径 */
const SIDE_BTN: number = 44;
/** 右侧竖排图标尺寸 */
const ICON_LG: number = 30;
/** 圆按钮底色 / 描边（画面上要压得住；描边太亮会让「圈」本身抢镜） */
const BTN_BG: string = 'rgba(0,0,0,0.46)';
const BTN_EDGE: string = 'rgba(255,255,255,0.16)';
/** 顶栏图标按钮的可点区域与图标尺寸 */
const TOP_BTN: number = 44;
const ICON_TOP: number = 26;
/** 底栏播放/暂停图标的可点区域与图标尺寸 */
const PLAY_BTN: number = 46;
const ICON_PLAY: number = 30;
/** 已标记片头/片尾时的高亮色（沿用 AppTheme.WARN 的金色系） */
const MARK_ON: string = '#FFC53D';

/**
 * 播放控制层。
 *
 * 横屏播放页和详情页全屏共用这一套，布局对齐主流影视 App：
 * - 顶栏：返回 + 标题/副标题 + ⋮（面板里只剩分享）
 * - 右侧竖排（垂直居中）：全屏 + 锁屏
 * - 底部两行：① 当前时间 + 缓冲进度条 + 总时长；② 动作行
 *   左「⏸/▶ / 下集 / 上集 / 标记片头 / 标记片尾」，右「字幕 / 倍速 / 画面 / 连播 / 选集」
 * - 倍速、画面比例点开后在底栏上方弹一小条 chips，不再藏进大面板
 *
 * 中央原来的三个大按钮已按需求删除（视觉太廉价）：上下集改成底栏文字，
 * 播放/暂停角标固定在动作行**最左侧、紧挨「下集」之前**（2026-10-12 用户定稿）。
 *
 * 注意：截图 / GIF 无法实现（AVPlayer 无 screenshot()，AVImageGenerator 读不了 http，
 * SURFACE 型 XComponent 也抓不到 componentSnapshot），故不提供，别再尝试加回。
 *
 * 做成独立 @Component 而不是 @Builder：控制层里有二十多处事件回调，
 * @Builder 内嵌双层箭头会触发 es2abc 的 "An arrow function cannot have a 'this' parameter"。
 */
@Component
export struct PlayerControls {
  @Prop title: string = '';
  @Prop epName: string = '';
  @Prop playing: boolean = false;
  @Prop isFullscreen: boolean = false;
  @Prop positionSec: number = 0;
  @Prop durationSec: number = 0;
  /** 已缓冲到的位置（秒），0 表示不支持/未知 */
  @Prop bufferedSec: number = 0;
  @Prop speed: number = 1.0;
  @Prop statusText: string = '';
  @Prop sourceName: string = '';
  @Prop epCount: number = 0;
  @Prop epIndex: number = 0;
  /** 播完自动下一集的开关状态 */
  @Prop autoNext: boolean = true;
  /*
   * ⚠️ 这里**没有**音量相关的 Prop / 节点 —— 系统音量面板 `AVVolumePanel` 已经搬到
   * `commons/component/VolumePanelHost.ets`，由页面根节点**常驻挂载一次**。
   * 原因：它内部是个 UIExtensionComponent，本层又是 `if (showControls)` 条件渲染的，
   * 每显隐一次就把系统音量扩展拆了重装，而且那个内部节点会吃掉整屏的触摸事件
   * （用户报「进度条一显示手势全废 + 缩小/锁住按钮点不动」的根因）。
   * 详见 VolumePanelHost 头部注释，别再往这里搬回来。
   */
  /** 投屏会话是否就绪（就绪才渲染投屏入口，没会话时组件会显示成不可用） */
  @Prop castReady: boolean = false;
  /** 是否已投屏到远端设备 */
  @Prop casting: boolean = false;
  /** 投屏设备名（投屏中显示在按钮旁边） */
  @Prop castDeviceName: string = '';
  /** 当前线路的清晰度标签（4K / 1080P / 高清…），空串表示源没标 */
  @Prop quality: string = '';
  /** 片源是否提供了可切换的音轨/字幕 */
  @Prop hasTracks: boolean = false;
  /** 画面比例模式（ASPECT_*） */
  @Prop aspectMode: number = 0;
  /** 锁屏中 */
  @Prop locked: boolean = false;
  /** 有片头标记且当前在片头范围内 → 非空则显示「跳过片头」 */
  @Prop skipIntroText: string = '';
  /** 有片尾标记且当前在片尾范围内 → 非空则显示「跳过片尾」 */
  @Prop skipOutroText: string = '';
  /** 是否已标过片头 / 片尾（用于面板按钮的高亮） */
  @Prop hasIntroMark: boolean = false;
  @Prop hasOutroMark: boolean = false;

  onBack: () => void = () => {
  };
  onPlayPause: () => void = () => {
  };
  onSeek: (sec: number) => void = () => {
  };
  /** 拖动过程中的预览（不真正 seek） */
  onSeekPreview: (sec: number) => void = () => {
  };
  onToggleFullscreen: () => void = () => {
  };
  onOpenEpisodes: () => void = () => {
  };
  onPrev: () => void = () => {
  };
  onNext: () => void = () => {
  };
  onSpeed: (v: number) => void = () => {
  };
  /** 切换「播完自动下一集」 */
  onToggleAutoNext: () => void = () => {
  };
  /** 打开音轨/字幕面板 */
  onOpenTracks: () => void = () => {
  };
  /** 点击画面空白处：切换控制栏显隐 */
  onToggleControls: () => void = () => {
  };
  /** 锁屏 / 解锁 */
  onToggleLock: () => void = () => {
  };
  /** 切换画面比例 */
  onAspect: (mode: number) => void = () => {
  };
  /** 分享当前影片 */
  onShare: () => void = () => {
  };
  /** 点投屏图标：由页面调 `CastUtil.showPicker()` 拉起系统设备选择面板 */
  onCast: () => void = () => {
  };
  /** 以当前位置标记片头结束 */
  onMarkIntro: () => void = () => {
  };
  /** 以当前位置标记片尾开始 */
  onMarkOutro: () => void = () => {
  };
  /** 跳到片头结束 */
  onSkipIntro: () => void = () => {
  };
  /** 跳到片尾开始 */
  onSkipOutro: () => void = () => {
  };

  /** 「更多」面板（只放分享 / 标记片头尾） */
  @State showMore: boolean = false;
  /** 底栏上方的选择面板：POPUP_* */
  @State popupKind: number = POPUP_NONE;

  build() {
    /*
     * ⚠️⚠️ hitTestBehavior 是这一层能不能用的关键，改任何节点前先读这段。
     *
     * 本层是**盖在手势层上面**的兄弟节点（Stack 后写的在上），而 ArkUI 的规则是：
     *   · `Default`（默认）—— 自己是触摸目标，并**阻塞兄弟节点**的触摸测试；
     *   · `Transparent`    —— 自己收，但**不阻塞兄弟**；
     *   · `None`           —— **自己不当目标**，子节点照常收；
     *   · `BLOCK_DESCENDANTS`（API 20）—— 自己**和整棵子树**都不当目标，也不阻塞兄弟。
     *
     * 于是「装饰用」的容器/文本只要是默认值，就会把下层 `PlayerGestureLayer` 的
     * 触摸整段吃掉 —— 症状正是「控制层一显示，双击暂停 / 亮度 / 音量全部失灵，
     * 点空白处也唤不出/收不起控制层」（用户报过）。
     *
     * 所以这里的规矩固定成四条，**新增任何节点都要照办**：
     *   ① 纯装饰、子树里没有任何可点东西（渐变底、标题、时间文本、状态行、动作行文字的背景容器）→ `BLOCK_DESCENDANTS`；
     *   ② 布局容器，但子树里混着可点元素（顶栏 / 底栏 / 右侧竖排）→ `None`；
     *   ③ 要能点、也要把竖直滑动让给手势层（底栏那些文字按钮、chips）→ `Transparent`；
     *   ④ 圆按钮 / Slider / 弹窗遮罩这种「按下就该独占」的 → 保持 `Default`。
     *
     * ⚠️ **本层只许放 ArkUI 自绘节点**。任何 UIExtension 型组件（`AVVolumePanel`、
     *    `AVCastPicker`、`UIExtensionComponent`）一旦放进来，它内部那个原生扩展节点会
     *    参与触摸测试并把整条事件吃掉 —— 2026-10-12 实测：控制条一显示，手势层与控制层
     *    的按钮**同时**失灵（日志 `TTHNI{ T: UIExtensionComponent }` + `TTHRTI:` 空）。
     *    系统音量面板因此被搬到 `VolumePanelHost`，由页面根节点常驻挂载。
     */
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.locked) {
        /* ---------- 锁屏：整层只留一个解锁按钮（右侧居中，和未锁时位置一致） ---------- */
        Column() {
          Row() {
            this.iconImg($r('app.media.player_ic_unlock'), ICON_LG)
          }
          .width(SIDE_BTN)
          .height(SIDE_BTN)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(BTN_BG)
          .borderRadius(SIDE_BTN / 2)
          .border({ width: 1, color: BTN_EDGE })
          .onClick(() => {
            this.onToggleLock();
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.End)
        .padding({ right: 20 })
        .hitTestBehavior(HitTestMode.None)
      } else {
        /* ==================== 右侧竖排：全屏 + 锁屏 ==================== */
        Column({ space: 14 }) {
          this.sideIconBtn(this.isFullscreen ? $r('app.media.player_ic_shrink') : $r('app.media.player_ic_expand'), () => {
            this.onToggleFullscreen()
          })
          Row() {
            this.iconImg($r('app.media.player_ic_lock'), ICON_LG)
          }
          .width(SIDE_BTN)
          .height(SIDE_BTN)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(BTN_BG)
          .borderRadius(SIDE_BTN / 2)
          .border({ width: 1, color: BTN_EDGE })
          .onClick(() => {
            this.onToggleLock();
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.End)
        .padding({ right: 20 })
        .hitTestBehavior(HitTestMode.None)

        /* ==================== 主体 ==================== */
        Column() {
          /* ---- 顶栏 ---- */
          Row() {
            Row() {
              this.iconImg($r('app.media.player_ic_back'), ICON_TOP)
            }
            .width(TOP_BTN)
            .height(TOP_BTN)
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.onBack();
            })

            Column() {
              Text(this.title)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textShadow({ radius: 6, color: '#99000000', offsetX: 0, offsetY: 1 })
                .hitTestBehavior(HitTestMode.None)
              if (this.subTitle().length > 0) {
                Text(this.subTitle())
                  .fontSize(11)
                  .fontColor('#D2D7E2')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 1 })
                  .textShadow({ radius: 5, color: '#99000000', offsetX: 0, offsetY: 1 })
                  .hitTestBehavior(HitTestMode.None)
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 2 })
            // 标题区是最大的一块「空白」，必须整个让给手势层，否则点它收不起控制层
            .hitTestBehavior(HitTestMode.None)

            /* 投屏入口：**自绘图标** + 拉起系统设备面板（`CastUtil.showPicker`）。
               ⚠️ 不要换回系统的 `AVCastPicker` 组件：它的红色 active 态由系统自己决定，
               插蓝牙耳机时某些机型也会让它变红（用户报过）。自绘的颜色只听 `casting`——
               而 `casting` 由 CastUtil 的四条判据算出，耳机永远不会被当成投屏。 */
            if (this.castReady) {
              Row() {
                this.iconImg(this.casting ? $r('app.media.player_ic_cast_on') : $r('app.media.player_ic_cast'),
                  ICON_TOP)
              }
              .width(TOP_BTN)
              .height(TOP_BTN)
              .justifyContent(FlexAlign.Center)
              .onClick(() => {
                this.onCast();
              })
              .hitTestBehavior(HitTestMode.Transparent)
            }

            Row() {
              this.dotsIcon(5)
            }
            .width(TOP_BTN)
            .height(TOP_BTN)
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.popupKind = POPUP_NONE;
              this.showMore = true;
            })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .hitTestBehavior(HitTestMode.None)

          /* ---- 状态提示（缓冲 / 解析中） ---- */
          if (this.statusText.length > 0) {
            Row({ space: 8 }) {
              LoadingProgress()
                .width(18)
                .height(18)
                .color('#FFFFFF')
              Text(this.statusText)
                .fontSize(13)
                .fontColor('#FFFFFF')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor('rgba(0,0,0,0.55)')
            .borderRadius(6)
            .margin({ top: 6 })
            // 纯提示，整棵子树对触摸不可见
            .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
          }

          /* ---- 跳过片头 / 片尾 ---- */
          Row({ space: 10 }) {
            if (this.skipIntroText.length > 0) {
              Text(`跳过片头 ${this.skipIntroText}`)
                .fontSize(12)
                .fontColor('#FFFFFF')
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .backgroundColor('rgba(0,0,0,0.55)')
                .borderRadius(AppTheme.RADIUS_PILL)
                .onClick(() => {
                  this.onSkipIntro();
                })
                .hitTestBehavior(HitTestMode.Transparent)
            }
            if (this.skipOutroText.length > 0) {
              Text('跳过片尾')
                .fontSize(12)
                .fontColor('#FFFFFF')
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .backgroundColor('rgba(0,0,0,0.55)')
                .borderRadius(AppTheme.RADIUS_PILL)
                .onClick(() => {
                  this.onSkipOutro();
                })
                .hitTestBehavior(HitTestMode.Transparent)
            }
          }
          .margin({ top: 8 })
          .hitTestBehavior(HitTestMode.None)

          Column()
            .width('100%')
            .layoutWeight(1)
            .hitTestBehavior(HitTestMode.None)

          /* ==================== 底栏 ==================== */
          Column() {
            /* ---- 倍速 / 画面比例：底栏上方弹一条 chips ---- */
            if (this.popupKind === POPUP_SPEED) {
              Column() {
                Text('倍速播放')
                  .fontSize(11)
                  .fontColor('#9BA3B4')
                  .width('100%')
                  .margin({ bottom: 6 })
                  .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(PlayerControls.speeds(), (s: number) => {
                    Text(`${s}x`)
                      .fontSize(12)
                      .fontColor(this.isSameSpeed(s) ? '#FFFFFF' : '#D6DAE3')
                      .backgroundColor(this.isSameSpeed(s) ? AppTheme.ACCENT : 'rgba(255,255,255,0.14)')
                      .padding({ left: 13, right: 13, top: 6, bottom: 6 })
                      .borderRadius(AppTheme.RADIUS_PILL)
                      .margin({ right: 8, bottom: 6 })
                      .onClick(() => {
                        this.popupKind = POPUP_NONE;
                        this.onSpeed(s);
                      })
                      .hitTestBehavior(HitTestMode.Transparent)
                  }, (s: number) => `sp_${s}`)
                }
                .width('100%')
                .hitTestBehavior(HitTestMode.None)
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 8 })
              .backgroundColor('rgba(22,26,40,0.90)')
              .borderRadius(12)
              .backgroundBlurStyle(BlurStyle.Thin)
              .margin({ bottom: 10 })
              .hitTestBehavior(HitTestMode.None)
            }

            if (this.popupKind === POPUP_ASPECT) {
              Column() {
                Text('画面比例')
                  .fontSize(11)
                  .fontColor('#9BA3B4')
                  .width('100%')
                  .margin({ bottom: 6 })
                  .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(PlayerControls.aspects(), (a: number) => {
                    Text(PlayerControls.aspectLabel(a))
                      .fontSize(12)
                      .fontColor(this.aspectMode === a ? '#FFFFFF' : '#D6DAE3')
                      .backgroundColor(this.aspectMode === a ? AppTheme.ACCENT : 'rgba(255,255,255,0.14)')
                      .padding({ left: 13, right: 13, top: 6, bottom: 6 })
                      .borderRadius(AppTheme.RADIUS_PILL)
                      .margin({ right: 8, bottom: 6 })
                      .onClick(() => {
                        this.popupKind = POPUP_NONE;
                        this.onAspect(a);
                      })
                      .hitTestBehavior(HitTestMode.Transparent)
                  }, (a: number) => `asp_${a}`)
                }
                .width('100%')
                .hitTestBehavior(HitTestMode.None)
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 8 })
              .backgroundColor('rgba(22,26,40,0.90)')
              .borderRadius(12)
              .backgroundBlurStyle(BlurStyle.Thin)
              .margin({ bottom: 10 })
              .hitTestBehavior(HitTestMode.None)
            }

            /* ---- 进度行：当前时间 · 进度条（含缓冲） · 总时长 ---- */
            Row() {
              Text(UrlUtil.formatTime(this.positionSec))
                .fontSize(12)
                .fontColor('#FFFFFF')
                .width(52)
                .maxLines(1)
                .textAlign(TextAlign.Start)
                .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)

              Stack({ alignContent: Alignment.Start }) {
                Row()
                  .width('100%')
                  .height(4)
                  .backgroundColor('rgba(255,255,255,0.24)')
                  .borderRadius(2)
                  .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
                if (this.bufferedPercent() > 0) {
                  Row()
                    .width(`${this.bufferedPercent()}%`)
                    .height(4)
                    .backgroundColor('rgba(255,255,255,0.45)')
                    .borderRadius(2)
                    .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
                }
                Slider({
                  value: this.positionSec,
                  min: 0,
                  max: this.durationSec > 0 ? this.durationSec : 1,
                  step: 1,
                  style: SliderStyle.OutSet
                })
                  .trackColor(Color.Transparent)
                  .selectedColor(AppTheme.ACCENT)
                  .blockColor('#FFFFFF')
                  .blockSize({ width: 13, height: 13 })
                  .trackThickness(4)
                  .width('100%')
                  .onChange((value: number, mode: SliderChangeMode) => {
                    if (mode === SliderChangeMode.Moving) {
                      this.onSeekPreview(value);
                    } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                      this.onSeek(value);
                    }
                  })
              }
              .layoutWeight(1)
              .height(24)
              // 容器让开（Slider 子节点仍然能拖）；上面那两条装饰 Rows 已 BLOCK_DESCENDANTS
              .hitTestBehavior(HitTestMode.None)

              Text(UrlUtil.formatTime(this.durationSec))
                .fontSize(12)
                .fontColor('#C6CCD8')
                .width(52)
                .maxLines(1)
                .textAlign(TextAlign.End)
                .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
            }
            .width('100%')
            .margin({ bottom: 2 })
            .hitTestBehavior(HitTestMode.None)

            /* ---- 动作行：左「⏸/▶ / 下集 / 上集 / 标记片头 / 标记片尾」 右「字幕 / 倍速 / 画面 / 连播 / 选集」 ---- */
            Row() {
              /* 播放/暂停角标放最前面（用户定稿：紧挨在「下集」之前） */
              Row() {
                if (this.playing) {
                  this.iconImg($r('app.media.player_ic_pause'), ICON_PLAY)
                } else {
                  this.iconImg($r('app.media.player_ic_play'), ICON_PLAY)
                }
              }
              .width(PLAY_BTN)
              .height(PLAY_BTN)
              .justifyContent(FlexAlign.Center)
              .onClick(() => {
                this.onPlayPause();
              })

              Text('下集')
                .fontSize(13)
                .fontColor(this.canNext() ? '#FFFFFF' : '#7C8394')
                .padding({ left: 2, right: 12, top: 4, bottom: 4 })
                .textShadow({ radius: 5, color: '#99000000', offsetX: 0, offsetY: 1 })
                .onClick(() => {
                  if (this.canNext()) {
                    this.onNext();
                  }
                })
                .hitTestBehavior(HitTestMode.Transparent)

              Text('上集')
                .fontSize(13)
                .fontColor(this.canPrev() ? '#FFFFFF' : '#7C8394')
                .padding({ left: 2, right: 12, top: 4, bottom: 4 })
                .textShadow({ radius: 5, color: '#99000000', offsetX: 0, offsetY: 1 })
                .onClick(() => {
                  if (this.canPrev()) {
                    this.onPrev();
                  }
                })
                .hitTestBehavior(HitTestMode.Transparent)

              Text(this.hasIntroMark ? '重标片头' : '标记片头')
                .fontSize(12.5)
                .fontColor(this.hasIntroMark ? MARK_ON : '#FFFFFF')
                .padding({ left: 0, right: 12, top: 4, bottom: 4 })
                .textShadow({ radius: 5, color: '#99000000', offsetX: 0, offsetY: 1 })
                .onClick(() => {
                  this.onMarkIntro();
                })
                .hitTestBehavior(HitTestMode.Transparent)

              Text(this.hasOutroMark ? '重标片尾' : '标记片尾')
                .fontSize(12.5)
                .fontColor(this.hasOutroMark ? MARK_ON : '#FFFFFF')
                .padding({ left: 0, right: 12, top: 4, bottom: 4 })
                .textShadow({ radius: 5, color: '#99000000', offsetX: 0, offsetY: 1 })
                .onClick(() => {
                  this.onMarkOutro();
                })
                .hitTestBehavior(HitTestMode.Transparent)

              Row()
                .layoutWeight(1)
                .hitTestBehavior(HitTestMode.None)

              if (this.hasTracks) {
                Text('字幕')
                  .fontSize(13)
                  .fontColor('#FFFFFF')
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .textShadow({ radius: 5, color: '#99000000', offsetX: 0, offsetY: 1 })
                  .onClick(() => {
                    this.popupKind = POPUP_NONE;
                    this.onOpenTracks();
                  })
                  .hitTestBehavior(HitTestMode.Transparent)
              }

              Text(this.speedLabel())
                .fontSize(13)
                .fontColor(this.isSameSpeed(1.0) ? '#FFFFFF' : AppTheme.ACCENT)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .textShadow({ radius: 5, color: '#99000000', offsetX: 0, offsetY: 1 })
                .onClick(() => {
                  this.showMore = false;
                  this.popupKind = this.popupKind === POPUP_SPEED ? POPUP_NONE : POPUP_SPEED;
                })
                .hitTestBehavior(HitTestMode.Transparent)

              Text('画面')
                .fontSize(13)
                .fontColor(this.aspectMode === ASPECT_FIT ? '#FFFFFF' : AppTheme.ACCENT)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .textShadow({ radius: 5, color: '#99000000', offsetX: 0, offsetY: 1 })
                .onClick(() => {
                  this.showMore = false;
                  this.popupKind = this.popupKind === POPUP_ASPECT ? POPUP_NONE : POPUP_ASPECT;
                })
                .hitTestBehavior(HitTestMode.Transparent)

              Text(this.autoNext ? '连播 开' : '连播 关')
                .fontSize(13)
                .fontColor(this.autoNext ? '#FFFFFF' : '#7C8394')
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .textShadow({ radius: 5, color: '#99000000', offsetX: 0, offsetY: 1 })
                .onClick(() => {
                  this.onToggleAutoNext();
                })
                .hitTestBehavior(HitTestMode.Transparent)

              Text(this.epLabel())
                .fontSize(13)
                .fontColor('#FFFFFF')
                .padding({ left: 10, right: 2, top: 4, bottom: 4 })
                .textShadow({ radius: 5, color: '#99000000', offsetX: 0, offsetY: 1 })
                .onClick(() => {
                  this.popupKind = POPUP_NONE;
                  this.onOpenEpisodes();
                })
                .hitTestBehavior(HitTestMode.Transparent)
            }
            .width('100%')
            .height(44)
            .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .padding({ bottom: 8 })
          .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 14, right: 14 })
        .justifyContent(FlexAlign.SpaceBetween)
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [
            ['rgba(0,0,0,0.62)', 0],
            ['rgba(0,0,0,0.16)', 0.30],
            ['rgba(0,0,0,0.06)', 0.60],
            ['rgba(0,0,0,0.74)', 1]
          ]
        })
        .hitTestBehavior(HitTestMode.None)
      }

      /* ==================== 更多面板：只剩分享 / 标记片头尾 ==================== */
      if (this.showMore && !this.locked) {
        Column() {
          /* 面板外的遮罩：点一下收起 */
          Column()
            .width('100%')
            .layoutWeight(1)
            .onClick(() => {
              this.showMore = false;
            })

          Column() {
            Row() {
              Text('更多')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .layoutWeight(1)
                .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
              Text('✕')
                .fontSize(15)
                .fontColor('#C6CCD8')
                .width(30)
                .height(30)
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.showMore = false;
                })
            }
            .width('100%')
            .margin({ bottom: 10 })
            .hitTestBehavior(HitTestMode.None)

            Row() {
              Text('分享')
                .fontSize(13)
                .fontColor('#D6DAE3')
                .backgroundColor('rgba(255,255,255,0.14)')
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                .borderRadius(AppTheme.RADIUS_PILL)
                .onClick(() => {
                  this.showMore = false;
                  this.onShare();
                })
            }
            .width('100%')
            .hitTestBehavior(HitTestMode.None)

            Text('片头/片尾标记已挪到底栏「上集」右侧，播到标记位置会自动提示跳过')
              .fontSize(10)
              .fontColor('#6B7280')
              .width('100%')
              .margin({ top: 10 })
              .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 18 })
          .backgroundColor('rgba(24,27,40,0.94)')
          .borderRadius({ topLeft: 16, topRight: 16 })
          .backgroundBlurStyle(BlurStyle.Thin)
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    /* 根节点：自己不当触摸目标（否则整层会挡住下层手势层），子节点照常收事件 */
    .hitTestBehavior(HitTestMode.None)
  }

  /* ==================== 图标 ==================== */
  /*
   * ⚠️ 图标一律用 `Image` 渲染 `resources/base/media/player_ic_*.svg`。
   *
   * 踩过两次坑，下面两个方案都别再捡回来：
   *  ① `Shape().viewPort({24×24})` —— 真机上不缩放子 Path 的内容：Path 按原始坐标
   *     1:1 绘制且贴在左上角，改 size 完全没效果；
   *  ② `Path().commands()` 自己算坐标 —— 命令里的坐标被按 **px** 解释（不是 vp），
   *     24 单位的路径在高密度屏上只剩 ~8vp，图标小得像颗米粒、而且仍然偏左上。
   *
   * `Image` 的 width/height 是明确的 vp，缩放由 SVG 的 viewBox 负责 —— 没有单位歧义。
   * 要换图标直接改/换 svg 文件，不要再回到自绘 Path。
   *
   * SVG 里的颜色已烘焙成白色，**不要**再用 `.fillColor()` 二次染色：
   * fillColor 只覆盖 `fill`，对 `stroke` 描边的图形无效，会造成"有的图标被染色有的没有"。
   */

  /** 图标（SVG 资源） */
  @Builder
  iconImg(res: Resource, size: number) {
    Image(res)
      .width(size)
      .height(size)
      .objectFit(ImageFit.Contain)
      .draggable(false)
      .interpolation(ImageInterpolation.High)
  }

  /** 右侧竖排的圆形按钮 */
  @Builder
  sideIconBtn(res: Resource, onTap: () => void) {
    Row() {
      this.iconImg(res, ICON_LG)
    }
    .width(SIDE_BTN)
    .height(SIDE_BTN)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(BTN_BG)
    .borderRadius(SIDE_BTN / 2)
    .border({ width: 1, color: BTN_EDGE })
    .onClick(() => {
      onTap();
    })
  }

  /** 顶栏「更多」的三点（自绘，避免 emoji/字形差异） */
  @Builder
  dotsIcon(size: number) {
    Column({ space: 5 }) {
      Row().width(size).height(size).borderRadius(size / 2).backgroundColor('#FFFFFF')
      Row().width(size).height(size).borderRadius(size / 2).backgroundColor('#FFFFFF')
      Row().width(size).height(size).borderRadius(size / 2).backgroundColor('#FFFFFF')
    }
  }

  /* ==================== 计算 ==================== */

  private subTitle(): string {
    const parts: string[] = [];
    if (this.sourceName.length > 0) {
      parts.push(this.quality.length > 0 ? `${this.sourceName}(${this.quality})` : this.sourceName);
    }
    if (this.epName.length > 0) {
      parts.push(this.epName);
    }
    return parts.join(' · ');
  }

  private isSameSpeed(s: number): boolean {
    return Math.abs(s - this.speed) < 0.001;
  }

  /** 底栏倍速按钮文案：正常速度显示「倍速」，否则显示当前倍率 */
  private speedLabel(): string {
    if (this.isSameSpeed(1.0)) {
      return '倍速';
    }
    return `${this.speed}x`;
  }

  /** 底栏选集按钮文案 */
  private epLabel(): string {
    if (this.epCount > 1) {
      return `选集 ${this.epIndex + 1}/${this.epCount}`;
    }
    return '选集';
  }

  private canPrev(): boolean {
    return this.epIndex > 0;
  }

  /** 集数未知（epCount<=0）时不拦，交给页面自己兜底 */
  private canNext(): boolean {
    return this.epCount <= 0 || this.epIndex < this.epCount - 1;
  }

  /** 缓冲进度百分比（0~100） */
  private bufferedPercent(): number {
    if (this.durationSec <= 0 || this.bufferedSec <= 0) {
      return 0;
    }
    const p: number = this.bufferedSec / this.durationSec * 100;
    return p > 100 ? 100 : Math.floor(p);
  }

  private static speeds(): number[] {
    return [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
  }

  private static aspects(): number[] {
    return [ASPECT_FIT, ASPECT_FILL, ASPECT_16_9, ASPECT_4_3];
  }

  private static aspectLabel(a: number): string {
    if (a === ASPECT_FILL) {
      return '铺满';
    }
    if (a === ASPECT_16_9) {
      return '16:9';
    }
    if (a === ASPECT_4_3) {
      return '4:3';
    }
    return '默认';
  }
}
