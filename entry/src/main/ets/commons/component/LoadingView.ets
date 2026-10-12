import { AppTheme } from '../theme/AppTheme';

/** 骨架流光：高光条宽度(vp) */
const SHIMMER_W: number = 88;
/** 流光扫过一遍的时长(ms) */
const SHIMMER_MS: number = 1250;
/** 两趟流光之间的间隔(ms)，留一点空拍更像"呼吸"而不是一直闪 */
const SHIMMER_REST_MS: number = 140;

/**
 * 骨架块（带流光扫过）。
 *
 * ⚠️ 为什么每块自己跑动画，而不是父组件统一驱动一个进度值：
 *   父组件统一驱动意味着每帧 setState 一次，一屏十几块全部跟着重建；
 *   改成每块自己在 onAppear 里跑「shift: 0 → 1」的动画后，
 *   变化的只有可动画属性 translate —— 父组件一帧都不用重绘，(GPU) 成本低得多。
 *
 * 用 setTimeout 串起每一趟而不是 animateTo(iterations:-1)：
 *   无限次数的 animateTo 在部分版本上"起点"会漂移，手串一趟动画起点永远是 0，行为确定。
 */
@Component
struct SkeletonBlock {
  @Prop w: number = 100;
  @Prop h: number = 100;
  @Prop r: number = 8;

  /** 高光条位移：0（完全在左侧外）→ 1（完全在右侧外） */
  @State shift: number = 0;
  private timerId: number = -1;

  aboutToDisappear(): void {
    this.stopShimmer();
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(AppTheme.CARD)

      Column()
        .width(SHIMMER_W)
        .height('100%')
        .linearGradient({
          angle: 0,
          colors: [
            ['rgba(255,255,255,0.0)', 0.0],
            ['rgba(255,255,255,0.075)', 0.5],
            ['rgba(255,255,255,0.0)', 1.0]
          ]
        })
        .translate({ x: this.shift * (this.w + SHIMMER_W) - SHIMMER_W })
    }
    .width(this.w)
    .height(this.h)
    .borderRadius(this.r)
    .clip(true)
    .backgroundColor(AppTheme.CARD)
    .onAppear(() => {
      this.sweep();
    })
  }

  private sweep(): void {
    this.stopShimmer();
    this.shift = 0;
    this.getUIContext().animateTo({ duration: SHIMMER_MS, curve: Curve.Linear }, () => {
      this.shift = 1;
    });
    this.timerId = setTimeout(() => {
      this.timerId = -1;
      this.sweep();
    }, SHIMMER_MS + SHIMMER_REST_MS);
  }

  private stopShimmer(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }
}

/** 列表加载中的骨架行（带流光） */
@Component
export struct VodListSkeleton {
  @Prop cardW: number = 110;
  @Prop posterH: number = 156;
  @Prop count: number = 3;
  @Prop gap: number = 9;

  build() {
    Row({ space: this.gap }) {
      ForEach(this.idx(), (i: number) => {
        Column() {
          SkeletonBlock({ w: this.cardW, h: this.posterH, r: AppTheme.RADIUS_CARD })
          SkeletonBlock({ w: this.cardW, h: 10, r: 4 })
            .margin({ top: 6 })
          SkeletonBlock({ w: this.cardW * 0.6, h: 9, r: 4 })
            .margin({ top: 5 })
        }
        .width(this.cardW)
        .alignItems(HorizontalAlign.Start)
      }, (i: number) => `sk_${i}`)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  private idx(): number[] {
    const out: number[] = [];
    for (let i = 0; i < this.count; i++) {
      out.push(i);
    }
    return out;
  }
}

/** 空状态 / 错误状态 */
@Component
export struct VodEmptyView {
  @Prop text: string = '暂无内容';
  @Prop hint: string = '';
  @Prop actionText: string = '';
  onAction: () => void = () => {
  };

  build() {
    Column({ space: 10 }) {
      Text('🎬')
        .fontSize(34)
        .opacity(0.5)
      Text(this.text)
        .fontSize(14)
        .fontColor(AppTheme.TEXT_SECONDARY)
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(12)
          .fontColor(AppTheme.TEXT_TERTIARY)
          .textAlign(TextAlign.Center)
          .padding({ left: 32, right: 32 })
      }
      if (this.actionText.length > 0) {
        Text(this.actionText)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor(AppTheme.ACCENT)
          .padding({ left: 18, right: 18, top: 8, bottom: 8 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .margin({ top: 6 })
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .padding({ top: 60, bottom: 40 })
    .justifyContent(FlexAlign.Center)
  }
}

/** 通用小标签 */
@Component
export struct TagChip {
  @Prop text: string = '';
  @Prop active: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Text(this.text)
      .fontSize(12)
      .fontColor(this.active ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
      .backgroundColor(this.active ? AppTheme.ACCENT : AppTheme.CARD)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(AppTheme.RADIUS_PILL)
      .onClick(() => {
        this.onTap();
      })
  }
}
