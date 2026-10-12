import { VodItem } from '../models/TvBoxModels';
import { VodPoster } from './VodPoster';
import { AppTheme } from '../theme/AppTheme';

/**
 * 横滑海报导轨（「最新电影」「最新电视剧」这类分区）。
 *
 * 为什么不写成 @Builder：@Builder 里再嵌 ForEach + 引用 this 的回调会触发
 * es2abc 报 "An arrow function cannot have a 'this' parameter"（详见 VodRowView 注释）。
 * 做成 @Component 后回调位于 build() 内，没有这个限制。
 */
@Component
export struct VodRail {
  @Prop title: string = '';
  @Prop cardW: number = 104;
  @Prop posterH: number = 148;
  @Prop gap: number = 9;
  /** 整段数据（每行按 key 重建，无需深度观测） */
  items: VodItem[] = [];
  onTap: (v: VodItem) => void = () => {
  };

  build() {
    Column() {
      Row() {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .layoutWeight(1)
        Text('左右滑动 ›')
          .fontSize(10)
          .fontColor(AppTheme.TEXT_TERTIARY)
      }
      .width('100%')
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, bottom: 8 })

      Scroll() {
        Row({ space: this.gap }) {
          ForEach(this.items, (v: VodItem) => {
            VodPoster({
              name: v.name,
              pic: v.pic,
              remarks: v.remarks,
              score: v.score,
              sub: this.subOf(v),
              cardW: this.cardW,
              posterH: this.posterH,
              onTap: () => {
                this.onTap(v);
              }
            })
          }, (v: VodItem) => `rail_${v.siteKey}_${v.id}`)
        }
        .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 副标题：优先展示更新状态，其次分类 + 年份 */
  private subOf(v: VodItem): string {
    const parts: string[] = [];
    if (v.typeName.length > 0) {
      parts.push(v.typeName);
    }
    if (v.year.length > 0) {
      parts.push(v.year);
    }
    return parts.join(' · ');
  }
}
