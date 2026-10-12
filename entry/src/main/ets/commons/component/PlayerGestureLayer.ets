import { AppTheme } from '../theme/AppTheme';
import { UrlUtil } from '../utils/UrlUtil';

/** 手势类别 */
const G_NONE = 0;
const G_SEEK = 1;
const G_BRIGHT = 2;
const G_VOLUME = 3;

/** 横滑一整屏最少/最多对应多少秒（片子太短或太长时夹一下，手感才稳） */
const SPAN_MIN_SEC = 60;
const SPAN_MAX_SEC = 600;
/** 判断「这次滑动该走横向还是纵向」的位移阈值（vp） */
const AXIS_LOCK_VP = 6;
/**
 * 双击判定窗口（ms）。
 * ⚠️ 不能靠 `TapGesture({count:2})` 和 `TapGesture({count:1})` 一起放进 Exclusive 组：
 * Exclusive 里谁先识别成功谁赢，而 count:1 在**第一次抬手**就立即成功，
 * count:2 永远等不到第二下 —— 表现就是「双击完全没反应」。
 * 所以只挂 count:1，自己按时间差分流：落在窗口内算双击（撤销待生效的单击），
 * 否则延迟这么久再当单击。副作用是单击显隐控制层有这么多毫秒延迟，所有播放器都这样。
 */
const DOUBLE_TAP_MS = 260;
/**
 * 「刚滑动过」的过滤窗口（ms）。
 * ⚠️ 实测日志里一次普通滑动抬手会**同时**出现 `PAN RACC` 和 `CLK RACC` ——
 * ClickRecognizer 的位移容忍度远大于 PanGesture 的 `distance:10`，所以滑动结束
 * 一定会顺带报一次假 Click。不拦掉的话：① 会显隐控制层（画面一闪）；
 * ② 假 Click 会刷新 lastTapMs，让随后 260ms 内的真实单击被误判成双击（画面莫名暂停）。
 * 用「最近一次滑动的时刻」整段过滤比布尔标记稳：布尔标记在手势被 Cancel 时会残留，
 * 反而把下一次真实单击吃掉。
 */
const PAN_TAP_GUARD_MS = 400;

/**
 * 播放器统一手势层 —— **它同时是画面 / 控制层的外层父容器**（页面用尾随闭包塞内容）。
 *
 * 收手感（和各家手机播放器一致）：
 *   · 单击            → onSingleTap（控制层显隐）
 *   · 双击            → onDoubleTap（暂停 / 继续）
 *   · 长按            → onLongPressStart/End（倍速快进，画面角上亮出 2x 角标）
 *   · 横滑            → 快进 / 快退（onSeekPreview 实时预览、onSeekTo 松手落点）
 *   · 左半屏竖滑      → 亮度（onBrightness）
 *   · 右半屏竖滑      → 音量（onVolume）
 *
 * ⚠️⚠️ **必须是「父容器」而不是「盖在最上面的兄弟透明层」**（2026-10-12 终版）：
 *   官方《多层级手势事件》—— 父子组件均绑定同类手势时**子组件优先**；`Default` 也
 *   「阻塞兄弟组件但不阻塞子组件」。做成兄弟节点就只能靠 z 序二选一：
 *   手势层赢 → 按钮全废；按钮赢 → 手势全废。做成父子关系后，控制层的按钮（子）
 *   天然优先，空白处才落到本层，**两边同时可用**，也不再依赖层高 / z 序。
 *
 * 三件事交给调用方：亮度/音量的当前值通过 @Prop 传进来（手势要在它基础上加减，
 * 提示也要显示百分比），落点通过回调回去。组件只做手势识别和提示浮层的绘制。
 *
 * ⚠️ 用单个 PanGesture(PanDirection.All) 按位移主轴分流，而不是挂三个方向的手势：
 * 方向不同会互相抢识别，主轴分流最稳，也不会和单击/双击打架。
 */
@Component
export struct PlayerGestureLayer {
  /** 是否启用手势总开关（详情页竖屏小窗时关掉：那时只留竖屏自己那层的 onClick 显隐控制条） */
  @Prop active: boolean = true;
  /** 锁屏：所有手势失效，只留「单击唤出解锁按钮」 */
  @Prop locked: boolean = false;
  /** 片长（秒），0 表示未知，横滑不生效 */
  @Prop durationSec: number = 0;
  /** 当前播放位置（秒），横滑起手基准 */
  @Prop positionSec: number = 0;
  /** 手势区实测尺寸（vp），横滑换算用 */
  @Prop areaW: number = 0;
  @Prop areaH: number = 0;
  /** 当前亮度 / 音量（0~1），纵向手势的起手值与提示显示。⚠️ 别叫 brightness，撞 ArkUI 内置属性 */
  @Prop brightLevel: number = 0.6;
  @Prop volume: number = 1;
  /**
   * 底部保留区高度（vp）：控制条可见时把它设成控制条那一带的高度。
   * ⚠️ **只对横滑（seek）生效** —— 那一片是进度条，拖它不能同时触发横滑。
   * 早期的写法是在 onPanStart 里无条件拦掉这一带，结果起手落在这儿连
   * **亮度 / 音量也一起失效**（用户反馈「进度条显示时调不了亮度」）。
   * 现在改成先锁主轴，只有判定为横滑时才放弃，纵向手势任何位置都能用。
   */
  @Prop bottomReservedH: number = 0;

  onSingleTap: () => void = () => {
  };
  onDoubleTap: () => void = () => {
  };
  /** 长按倍速：开始 / 结束（结束要还原倍速） */
  onLongPressStart: () => void = () => {
  };
  onLongPressEnd: () => void = () => {
  };
  /** 横滑过程中的目标位置（实时预览，不 seek） */
  onSeekPreview: (sec: number) => void = () => {
  };
  /** 松手后的最终落点 */
  onSeekTo: (sec: number) => void = () => {
  };
  /** 横滑被取消 / 没构成有效落点：调用方要清掉「预览中」标记 */
  onSeekCancel: () => void = () => {
  };
  /** 亮度目标值 0~1 */
  onBrightness: (v: number) => void = () => {
  };
  /** 音量目标值 0~1 */
  onVolume: (v: number) => void = () => {
  };

  /** 当前提示类别 */
  @State hintKind: number = G_NONE;
  /** 横滑：起手位置 / 目标位置（秒） */
  @State seekAnchorSec: number = 0;
  @State seekTargetSec: number = 0;
  /** 长按倍速角标 */
  @State longPressOn: boolean = false;

  /* ---------- 单击 / 双击分流 ---------- */
  /** 上一次单击的时间戳（ms），0 表示没有待判定的点击 */
  private lastTapMs: number = 0;
  /** 待生效的单击定时器 id，-1 表示没有 */
  private tapTimer: number = -1;

  /**
   * 内容插槽：画面 + 控制层全部放进来（页面用尾随闭包传入）。
   *
   * ⚠️⚠️ 它们是本组件的**子节点**，这是整件事的关键 —— 官方《多层级手势事件》：
   *   · 响应优先级 1 —— **当父子组件均绑定同一类手势时，子组件优先于父组件触发**；
   *   · `HitTestMode.Default` —— 自身如果命中会阻塞兄弟组件，**但是不阻塞子组件**。
   * 所以按钮（子）的 onClick 天然压过本层（父）的手势，而空白处轮到本层 —— 两边同时可用。
   */
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {
    /* 占位：页面没传内容时留一个 0 尺寸盒子，避免 @BuilderParam 没有默认实现 */
    Column()
      .width(0)
      .height(0)
  }

  /* ---------- 手势内部状态 ---------- */
  /** 本次滑动分流后的类别 */
  private panKind: number = G_NONE;
  /** 起手分流出的类别（G_BRIGHT / G_VOLUME） */
  private anchor: number = 0;
  /**
   * 起手时**快照**的亮度 / 音量（0~1）。
   * ⚠️⚠️ 纵向手势必须基于起手值算，绝不能用实时的 `this.brightLevel` / `this.volume`：
   * 调用方在每次 onBrightness / onVolume 回调里都会把新值写回 @Prop，
   * 而 `event.offsetY` 是**相对起手点的累计位移** —— 「实时值 + 累计位移」= 二次累积，
   * 一次正常滑动就能把音量从满档砸到 0（实测日志：50ms 内 volumeLevel 14→13→11→9→6→3→0，
   * 用户感知就是「声音突然没了 / 调音量时好时坏」）。
   */
  private anchorBright: number = 0.6;
  private anchorVolume: number = 1;
  /** 起手坐标（vp）：纵向手势按左右半屏分流，横滑要判断是不是从底部进度条那条带起手 */
  private startX: number = 0;
  private startY: number = -1;
  /** 是否已经用位移锁定了主轴（避免纵向滑动中途又变成横滑） */
  private axisLocked: boolean = false;
  /** 是否产生了超过阈值的位移（没有就当点击） */
  private moved: boolean = false;
  /**
   * 最近一次滑动刷新的时刻（ms）。
   * 用来把「滑动抬手时 ClickRecognizer 顺手报出来的假 Click」整段过滤掉，
   * 详见 PAN_TAP_GUARD_MS 的说明。初值 0 = 从没滑过，不会误伤第一次单击。
   */
  private lastPanMs: number = 0;

  build() {
    /*
     * ⚠️⚠️ 手势绑在**这个父容器**上，由它包住画面 + 控制层（2026-10-12 终版）。
     *
     * 为什么不是「单独一层透明触摸层」：那样它和 `PlayerControls` 就是 Stack 里的
     * **兄弟节点**，兄弟之间只按 z 序（后写的在上）分胜负 —— 于是「手势层赢」和
     * 「按钮赢」只能二选一，前后翻了五六版都治不好（日志里 `Touch test result is empty.`）。
     *
     * 官方《多层级手势事件》给的是父子关系：
     *   · 响应优先级 1 —— **父子组件均绑定同一类手势时，子组件优先于父组件触发**；
     *   · `HitTestMode.Default` —— 自身如果命中会阻塞兄弟组件，**但是不阻塞子组件**；
     *   · 触摸测试会「自上而下遍历……将结果逐级向上冒泡至父组件」——
     *     父容器永远在响应链上，所以**不会再出现结果为空、整个画面失灵**的情况。
     * ⇒ 按钮是子、手势是父：按钮的 onClick 天然优先，空白处才轮到本层。
     */
    Stack({ alignContent: Alignment.Center }) {
      /* ==================== 内容：画面 + 控制层（页面用尾随闭包传入） ==================== */
      this.content()

      /* 横滑 / 纵向手势的中央提示 —— 纯装饰，整棵子树都不参与触摸测试 */
      if (this.hintVisible()) {
        Column({ space: 4 }) {
          Text(this.hintTitle())
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Text(this.hintSub())
            .fontSize(12)
            .fontColor('#E3E7EF')
        }
        .padding({ left: 22, right: 22, top: 12, bottom: 12 })
        .backgroundColor('rgba(0,0,0,0.66)')
        .borderRadius(10)
        .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
      }

      /* 长按倍速角标 */
      if (this.longPressOn) {
        Row() {
          Text('2.0x 快进中')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(AppTheme.ACCENT)
        .borderRadius(AppTheme.RADIUS_PILL)
        .align(Alignment.TopEnd)
        .margin({ top: 54, right: 26 })
        .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
      }
    }
    .width('100%')
    .height('100%')
    /* 单击 / 双击 / 长按 2x：互斥组，谁先满足条件谁赢 */
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ repeat: false, duration: 450 })
          .onAction(() => {
            if (!this.locked && this.active) {
              this.longPressOn = true;
              // 长按已在跑，把待生效的单击丢掉，否则松手后控制层莫名闪一下
              this.clearTapTimer();
              this.lastTapMs = 0;
              this.onLongPressStart();
            }
          })
          .onActionEnd(() => {
            if (this.longPressOn) {
              this.longPressOn = false;
              this.onLongPressEnd();
            }
          }),
        TapGesture({ count: 1 })
          .onAction(() => {
            this.handleTap();
          })
      )
    )
    /* 横滑快进退 / 纵向亮度音量：单独并行，不和上面那组抢（位移主轴自己分流） */
    .parallelGesture(
      PanGesture({ fingers: 1, direction: PanDirection.All, distance: 10 })
        .onActionStart((event: GestureEvent) => {
          this.onPanStart(event);
        })
        .onActionUpdate((event: GestureEvent) => {
          this.onPanUpdate(event);
        })
        .onActionEnd(() => {
          this.onPanEnd();
        })
        .onActionCancel(() => {
          this.onPanCancel();
        })
    )
  }

  /* ==================== 单击 / 双击 ==================== */

  aboutToDisappear(): void {
    this.clearTapTimer();
  }

  /**
   * 只有 count:1 一个点击手势，靠时间差把「第二下」认出来当双击。
   * 双击时要把已经排队的单击撤掉，否则会先显隐控制层再暂停（闪一下很难看）。
   */
  private handleTap(): void {
    /* 手势层被关掉时（详情页竖屏小窗，`active=false`）完全不接管点击：
     * 那时竖屏自己那层 `onClick`（现在是本组件的**子节点**，天然优先）负责显隐控制条。 */
    if (!this.active) {
      this.clearTapTimer();
      this.lastTapMs = 0;
      return;
    }
    /* 刚滑动过 → 这次 Click 是抬手顺带报的假事件，既不显隐控制层也不参与双击判定。 */
    if (Date.now() - this.lastPanMs < PAN_TAP_GUARD_MS) {
      this.clearTapTimer();
      this.lastTapMs = 0;
      return;
    }
    const now: number = Date.now();
    if (this.lastTapMs > 0 && now - this.lastTapMs <= DOUBLE_TAP_MS) {
      this.lastTapMs = 0;
      this.clearTapTimer();
      if (!this.locked) {
        this.onDoubleTap();
      }
      return;
    }
    this.lastTapMs = now;
    this.clearTapTimer();
    this.tapTimer = setTimeout(() => {
      this.tapTimer = -1;
      this.lastTapMs = 0;
      this.onSingleTap();
    }, DOUBLE_TAP_MS);
  }

  private clearTapTimer(): void {
    if (this.tapTimer >= 0) {
      clearTimeout(this.tapTimer);
      this.tapTimer = -1;
    }
  }

  /* ==================== 手势分流 ==================== */

  private onPanStart(event: GestureEvent): void {
    this.panKind = G_NONE;
    this.axisLocked = false;
    this.moved = false;
    this.hintKind = G_NONE;
    /* Pan 能被识别（distance:10）就说明有真实位移，记下时刻用于过滤抬手时的假 Click */
    this.lastPanMs = Date.now();
    if (this.locked || !this.active) {
      return;
    }
    /* 只记起手坐标，这里**不做任何拦截**：
     * 纵向的亮度 / 音量在屏幕任何位置都该能调（包括底部控制条那一带）；
     * 「底部那条带让给进度条」的判定推迟到锁定横滑之后再做。 */
    this.startX = this.fingerX(event);
    this.startY = this.fingerY(event);
    /* 纵向手势的基准值必须在**起手这一刻**快照下来（见 anchorBright / anchorVolume 说明） */
    this.anchorBright = this.brightLevel;
    this.anchorVolume = this.volume;
    // 纵向手势按左右半屏分流，起手时就要定下来
    this.anchor = this.startX < (this.areaW > 0 ? this.areaW / 2 : 180) ? G_BRIGHT : G_VOLUME;
  }

  private onPanUpdate(event: GestureEvent): void {
    if (this.locked || !this.active) {
      return;
    }
    const dx: number = event.offsetX;
    const dy: number = event.offsetY;
    if (!this.axisLocked) {
      if (Math.abs(dx) < AXIS_LOCK_VP && Math.abs(dy) < AXIS_LOCK_VP) {
        return;
      }
      // 锁定主轴：横向位移更大 → 快进/快退；否则纵向 → 亮度/音量
      if (Math.abs(dx) >= Math.abs(dy)) {
        if (this.durationSec <= 0 || this.inReservedBottom()) {
          // 片长未知，或从底部进度条那一带起手 —— 横滑让给 Slider，本次不接管
          this.panKind = G_NONE;
        } else {
          this.panKind = G_SEEK;
          this.seekAnchorSec = this.positionSec;
          this.seekTargetSec = this.positionSec;
          this.hintKind = G_SEEK;
        }
      } else {
        this.panKind = this.anchor;
        this.hintKind = this.anchor;
      }
      this.axisLocked = true;
    }
    this.moved = true;
    // 持续刷新：抬手前最后一次 move 才代表"滑动真正结束的时刻"
    this.lastPanMs = Date.now();

    if (this.panKind === G_SEEK) {
      const w: number = this.areaW > 0 ? this.areaW : 640;
      const span: number = PlayerGestureLayer.seekSpan(this.durationSec);
      let target: number = this.seekAnchorSec + dx / w * span;
      if (target < 0) {
        target = 0;
      }
      if (target > this.durationSec) {
        target = this.durationSec;
      }
      this.seekTargetSec = target;
      this.onSeekPreview(Math.round(target));
    } else if (this.panKind === G_BRIGHT) {
      // 用起手快照当基准（不能用 this.brightLevel，会二次累积）
      this.onBrightness(PlayerGestureLayer.byVertical(this.anchorBright, dy, this.areaH));
    } else if (this.panKind === G_VOLUME) {
      this.onVolume(PlayerGestureLayer.byVertical(this.anchorVolume, dy, this.areaH));
    }
  }

  private onPanEnd(): void {
    const kind: number = this.panKind;
    const moved: boolean = this.moved;
    this.panKind = G_NONE;
    this.moved = false;
    this.axisLocked = false;
    this.hintKind = G_NONE;
    if (kind === G_SEEK) {
      if (moved && Math.abs(this.seekTargetSec - this.seekAnchorSec) >= 1) {
        this.onSeekTo(Math.round(this.seekTargetSec));
      } else {
        this.onSeekCancel();
      }
    }
    // 纵向手势没有「落点」，值已经通过 onBrightness/onVolume 实时下发过了
  }

  private onPanCancel(): void {
    const kind: number = this.panKind;
    this.panKind = G_NONE;
    this.moved = false;
    this.axisLocked = false;
    this.hintKind = G_NONE;
    if (kind === G_SEEK) {
      this.onSeekCancel();
    }
  }

  /**
   * 纵向手势映射：向上滑变亮/变响。
   * 手指移动一屏高度 ≈ 调整满量程 1.0，结果夹在 [0.02, 1]。
   */
  private static byVertical(base: number, dy: number, areaH: number): number {
    const h: number = areaH > 0 ? areaH : 640;
    // 屏幕坐标向下为正，所以是减
    let v: number = base - dy / h;
    if (v < 0.02) {
      v = 0.02;
    }
    if (v > 1) {
      v = 1;
    }
    return v;
  }

  /** 整屏横滑对应的秒数：约总时长的一半，夹在 60 ~ 600 秒 */
  private static seekSpan(duration: number): number {
    const half: number = duration * 0.5;
    if (half < SPAN_MIN_SEC) {
      return SPAN_MIN_SEC;
    }
    if (half > SPAN_MAX_SEC) {
      return SPAN_MAX_SEC;
    }
    return Math.round(half);
  }

  /** 取第一根手指在手势组件内的 X 坐标（vp）；拿不到返回 0 */
  private fingerX(event: GestureEvent): number {
    const list: FingerInfo[] = event.fingerList;
    if (list === undefined || list === null || list.length === 0) {
      return 0;
    }
    return list[0].localX;
  }

  /** 取第一根手指在手势组件内的 Y 坐标（vp）；拿不到返回 -1 */
  private fingerY(event: GestureEvent): number {
    const list: FingerInfo[] = event.fingerList;
    if (list === undefined || list === null || list.length === 0) {
      return -1;
    }
    return list[0].localY;
  }

  /**
   * 本次滑动是不是从底部「控制条保留区」起手的。
   * 只有横滑（seek）需要让开这一带（那片是可拖的进度条），
   * 亮度 / 音量走纵向，任何时候都不受它限制。
   */
  private inReservedBottom(): boolean {
    if (this.bottomReservedH <= 0 || this.areaH <= 0 || this.startY < 0) {
      return false;
    }
    return this.startY > this.areaH - this.bottomReservedH;
  }

  /* ==================== 提示文案 ==================== */

  private hintVisible(): boolean {
    return this.hintKind !== G_NONE;
  }

  /** 提示主文案。刻意不用 ⏩/☀/🔊 这类符号：部分设备会渲染成彩色 emoji，和深色浮层不搭 */
  private hintTitle(): string {
    if (this.hintKind === G_SEEK) {
      const d: number = Math.round(this.seekTargetSec - this.seekAnchorSec);
      if (d >= 0) {
        return `快进 ${UrlUtil.formatTime(d)}`;
      }
      return `快退 ${UrlUtil.formatTime(-d)}`;
    }
    if (this.hintKind === G_BRIGHT) {
      return `${Math.round(this.brightLevel * 100)}%`;
    }
    if (this.hintKind === G_VOLUME) {
      return `${Math.round(this.volume * 100)}%`;
    }
    return '';
  }

  private hintSub(): string {
    if (this.hintKind === G_SEEK) {
      return `${UrlUtil.formatTime(this.seekTargetSec)} / ${UrlUtil.formatTime(this.durationSec)}`;
    }
    return this.hintKind === G_BRIGHT ? '亮度' : '音量';
  }
}
