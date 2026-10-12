import { AppTheme } from '../theme/AppTheme';

/**
 * 影视海报卡片。
 *
 * 参数用 @Prop 逐个传入（而不是传整个 VodItem），原因：
 *   ArkTS 的 @Prop 只对基础类型做深拷贝观测；传对象容易出现「列表刷新了但卡片文字没变」。
 *   逐个 @Prop 传标量，配合 ForEach 的 keyGenerator，刷新行为是确定的。
 */
@Component
export struct VodPoster {
  @Prop name: string = '';
  @Prop pic: string = '';
  @Prop remarks: string = '';
  @Prop score: string = '';
  @Prop sub: string = '';
  @Prop cardW: number = 110;
  @Prop posterH: number = 156;

  /** 海报不透明度：解码完成后淡入，避免列表里"啪"地整片跳出来 */
  @State picAlpha: number = 1;

  onTap: () => void = () => {
  };

  aboutToAppear(): void {
    // pic 为空时 Image 会退回 alt 占位图，这时不能让它淡入，否则连占位图也看不见
    this.picAlpha = this.pic.length > 0 ? 0 : 1;
  }

  build() {
    Column() {
      /*
       * Stack 的 alignContent 作用于所有子节点，无法分别对齐，
       * 因此用「外层 BottomStart 放备注 + 内层整幅 TopEnd 放评分」两层嵌套实现两个角标。
       */
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(this.pic)
          .alt($r('app.media.background'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .backgroundColor(AppTheme.PLACEHOLDER)
          .draggable(false)
          .opacity(this.picAlpha)
          .onComplete(() => {
            this.fadeIn();
          })
          .onError(() => {
            this.fadeIn();
          })

        Stack({ alignContent: Alignment.TopEnd }) {
          if (this.score.length > 0 && this.scoreValue() > 0) {
            Text(this.scoreValue().toFixed(1))
              .fontSize(10)
              .fontColor(AppTheme.GOLD)
              .fontWeight(FontWeight.Bold)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .backgroundColor(AppTheme.BADGE_BG)
              .borderRadius(4)
              .margin({ top: 4, right: 4 })
          }
        }
        .width('100%')
        .height('100%')

        // 底部备注（更新至xx集 / 全xx集）
        if (this.remarks.length > 0) {
          Text(this.remarks)
            .fontSize(10)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor(AppTheme.BADGE_BG)
            .borderRadius({ topLeft: 6, topRight: 6 })
            .constraintSize({ maxWidth: this.cardW - 8 })
        }
      }
      .width('100%')
      .height(this.posterH)
      .borderRadius(AppTheme.RADIUS_CARD)
      .clip(true)
      .backgroundColor(AppTheme.PLACEHOLDER)

      Text(this.name)
        .fontSize(12)
        .fontColor(AppTheme.TEXT_PRIMARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 5 })

      Text(this.subLine())
        .fontSize(10)
        .fontColor(AppTheme.TEXT_TERTIARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 1 })
    }
    .width(this.cardW)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onTap();
    })
  }

  /** 解码完成（或失败退回占位图）后淡入 */
  private fadeIn(): void {
    if (this.picAlpha >= 1) {
      return;
    }
    this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseOut }, () => {
      this.picAlpha = 1;
    });
  }

  private scoreValue(): number {
    if (this.score.length === 0) {
      return 0;
    }
    const n: number = parseFloat(this.score);
    return isNaN(n) ? 0 : n;
  }

  private subLine(): string {
    const parts: string[] = [];
    if (this.sub !== undefined && this.sub.length > 0) {
      parts.push(this.sub);
    }
    return parts.join(' · ');
  }
}
