import { VodRow } from '../models/RowModel';
import { VodItem } from '../models/TvBoxModels';
import { VodPoster } from './VodPoster';

/**
 * 一行海报。
 *
 * 为什么单独做成 @Component 而不是 @Builder：
 *   @Builder 里再嵌一层引用 this 的箭头函数（ForEach 回调 → onTap 回调）会触发
 *   es2abc 报 "An arrow function cannot have a 'this' parameter"。
 *   做成结构体后事件回调位于 build() 内，没有这个限制。
 */
@Component
export struct VodRowView {
  @Prop cardW: number = 110;
  @Prop posterH: number = 156;
  @Prop gap: number = 9;
  /** 副标题优先显示站点名（搜索结果用：多源聚合后要能看出这条来自哪个源） */
  @Prop preferSiteName: boolean = false;
  /** 整行数据（按 key 重建，无需深度观测） */
  row: VodRow = new VodRow();
  onTap: (v: VodItem) => void = () => {
  };

  build() {
    Row({ space: this.gap }) {
      ForEach(this.row.items, (v: VodItem) => {
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
      }, (v: VodItem) => `${v.siteKey}_${v.id}_${v.playUrl.length}`)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .justifyContent(FlexAlign.Start)
  }

  private subOf(v: VodItem): string {
    const parts: string[] = [];
    if (this.preferSiteName) {
      if (v.siteName !== undefined && v.siteName.length > 0) {
        parts.push(v.siteName);
      }
      if (v.year !== undefined && v.year.length > 0) {
        parts.push(v.year);
      }
      return parts.join(' · ');
    }
    if (v.year !== undefined && v.year.length > 0) {
      parts.push(v.year);
    }
    if (v.typeName !== undefined && v.typeName.length > 0) {
      parts.push(v.typeName);
    } else if (v.siteName !== undefined && v.siteName.length > 0) {
      parts.push(v.siteName);
    }
    return parts.join(' · ');
  }
}
