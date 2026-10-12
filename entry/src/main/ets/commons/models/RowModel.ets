import { EpisodeModel, VodItem } from './TvBoxModels';

/** 海报墙的一行：把一维列表按当前列数切成行，便于 List + LazyForEach 高效渲染 */
export class VodRow {
  key: string = '';
  items: VodItem[] = [];

  /**
   * 按列数把列表切行。
   * @param prefix 行的 key 前缀 —— 必须带上「数据身份」（如 分类 key + 列数），
   *               否则切换分类后 key 不变，LazyForEach 会复用旧内容导致串行显示。
   */
  static chunk(list: VodItem[], columns: number, prefix: string): VodRow[] {
    const rows: VodRow[] = [];
    const cols: number = columns < 1 ? 1 : columns;
    let i: number = 0;
    while (i < list.length) {
      const row: VodRow = new VodRow();
      const end: number = i + cols > list.length ? list.length : i + cols;
      for (let j = i; j < end; j++) {
        row.items.push(list[j]);
      }
      row.key = `${prefix}_${i}_${cols}`;
      rows.push(row);
      i = end;
    }
    return rows;
  }
}

/** 剧集网格的一行 */
export class EpisodeRow {
  key: string = '';
  items: EpisodeModel[] = [];

  static chunk(list: EpisodeModel[], columns: number, prefix: string): EpisodeRow[] {
    const rows: EpisodeRow[] = [];
    const cols: number = columns < 1 ? 1 : columns;
    let i: number = 0;
    while (i < list.length) {
      const row: EpisodeRow = new EpisodeRow();
      const end: number = i + cols > list.length ? list.length : i + cols;
      for (let j = i; j < end; j++) {
        row.items.push(list[j]);
      }
      row.key = `${prefix}_${i}_${cols}`;
      rows.push(row);
      i = end;
    }
    return rows;
  }
}
