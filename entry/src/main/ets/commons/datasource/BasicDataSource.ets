import { EpisodeModel, VodItem } from '../models/TvBoxModels';
import { VodRow, EpisodeRow } from '../models/RowModel';

/**
 * LazyForEach 数据源基类。
 *
 * 用法：
 *   @State private ds: VodDataSource = new VodDataSource();
 *   LazyForEach(this.ds, (item: VodItem) => { ... }, (item: VodItem) => item.siteKey + item.id)
 *
 * 注意（ArkTS 限制）：@State 装饰的嵌套对象属性赋值无法被观察到，
 * 因此这里所有变更都走「整体替换 + notifyDataReload」或明确的增量通知接口。
 */
export class BasicDataSource<T extends Object> implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: T[] = [];

  public totalCount(): number {
    return this.items.length;
  }

  public getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /* ------------------------- 数据操作 ------------------------- */

  public getItems(): T[] {
    return this.items;
  }

  public getItem(index: number): T {
    return this.items[index];
  }

  /** 整体替换（最常用） */
  public setItems(list: T[]): void {
    this.items = list === undefined ? [] : list;
    this.notifyDataReload();
  }

  /** 追加一批（分页加载） */
  public appendItems(list: T[]): void {
    if (list === undefined || list.length === 0) {
      return;
    }
    const start: number = this.items.length;
    for (let i = 0; i < list.length; i++) {
      this.items.push(list[i]);
    }
    this.notifyDataAddRange(start, list.length);
  }

  public clear(): void {
    this.items = [];
    this.notifyDataReload();
  }

  /* ------------------------- 通知 ------------------------- */

  public notifyDataReload(): void {
    this.listeners.forEach((l: DataChangeListener) => {
      l.onDataReloaded();
    });
  }

  public notifyDataAdd(index: number): void {
    this.listeners.forEach((l: DataChangeListener) => {
      l.onDataAdd(index);
    });
  }

  public notifyDataChange(index: number): void {
    this.listeners.forEach((l: DataChangeListener) => {
      l.onDataChange(index);
    });
  }

  public notifyDataDelete(index: number): void {
    this.listeners.forEach((l: DataChangeListener) => {
      l.onDataDelete(index);
    });
  }

  public notifyDataMove(from: number, to: number): void {
    this.listeners.forEach((l: DataChangeListener) => {
      l.onDataMove(from, to);
    });
  }

  public notifyDatasetChange(operations: DataOperation[]): void {
    this.listeners.forEach((l: DataChangeListener) => {
      l.onDatasetChange(operations);
    });
  }

  private notifyDataAddRange(start: number, count: number): void {
    const ops: DataOperation[] = [];
    for (let i = 0; i < count; i++) {
      ops.push({ type: DataOperationType.ADD, index: start + i, count: 1 });
    }
    this.notifyDatasetChange(ops);
  }
}

/** 影视条目数据源 */
export class VodDataSource extends BasicDataSource<VodItem> {
}

/** 剧集数据源 */
export class EpisodeDataSource extends BasicDataSource<EpisodeModel> {
}

/** 海报行数据源（首页 / 搜索页的 List 用） */
export class VodRowDataSource extends BasicDataSource<VodRow> {
}

/** 剧集行数据源 */
export class EpisodeRowDataSource extends BasicDataSource<EpisodeRow> {
}
