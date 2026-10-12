/**
 * TVBox / 影视仓 配置数据模型
 *
 * 说明: ArkTS 是强类型语言, 禁止 any/unknown, 因此这里为配置文件的每个字段都声明显式类型。
 * 对于确实无法固定的字段(如 parses[].ext), 采用具体接口 + 运行时兜底, 不引入 any。
 */

/* ============================ sites ============================ */

export interface SiteModel {
  key: string;
  name: string;
  /** 0=XML  1=JSON(MacCMS)  3=Spider */
  type: number;
  api: string;
  searchable?: number;
  quickSearch?: number;
  filterable?: number;
  changeable?: number;
  /** 搜索参数模板, {wd} 会被替换为关键词 */
  ext?: string;
  /** 站点级 jar, 覆盖全局 spider */
  jar?: string;
  /** 部分源额外提供 playUrl 模板 */
  playUrl?: string;
  /** 播放页需要额外请求头时使用 */
  header?: Record<string, string>;
  /** 有些源用 categories 直给分类 */
  categories?: string[];
}

/* ============================ parses ============================ */

export interface ParseExtModel {
  flag?: string[];
  header?: Record<string, string>;
  ua?: string;
  referer?: string;
  format?: string;
}

export interface ParseModel {
  name: string;
  /** 0=普通嗅探/跳转  1=Json解析  2=Json扩展  3=聚合 */
  type: number;
  url: string;
  ext?: ParseExtModel;
}

/* ============================ classes ============================ */

export interface FilterValueModel {
  /** 显示名 */
  n: string;
  /** 实际值 */
  v: string;
}

export interface FilterItemModel {
  key: string;
  name: string;
  value: FilterValueModel[];
}

export interface FilterByModel {
  by?: FilterItemModel[];
}

export interface ClassModel {
  type_id: number | string;
  type_name: string;
  type_flag?: string;
  /** 父分类 id。MacCMS `?ac=list` 会返回；0 或缺失表示一级分类 */
  type_pid?: number | string;
  filters?: FilterByModel;
}

/** `?ac=list` 返回的分类列表（MacCMS 固定结构） */
export interface ClassListResp {
  code?: number;
  msg?: string;
  class?: ClassModel[];
}

/* ============================ 多仓 ============================ */

export interface WareItemModel {
  url: string;
  name?: string;
}

/** 顶层配置。既有单仓(sites)也有多仓(urls)，用同一个接口承载 */
export interface ConfigModel {
  name?: string;
  logo?: string;
  wallpaper?: string;
  spider?: string;
  flags?: string[];
  sites?: SiteModel[];
  parses?: ParseModel[];
  classes?: ClassModel[];
  /** 多仓时存在；元素可能是字符串，也可能是 {url,name} */
  urls?: Object[];
  /** 部分配置把仓库列表放在 repositories */
  repositories?: Object[];
}

/* ============================ MacCMS 接口响应 ============================ */

export interface VodRawModel {
  vod_id?: number | string;
  vod_name?: string;
  vod_pic?: string;
  vod_remarks?: string;
  vod_year?: string;
  vod_area?: string;
  vod_lang?: string;
  vod_actor?: string;
  vod_director?: string;
  vod_score?: string;
  vod_content?: string;
  vod_blurb?: string;
  type_name?: string;
  vod_play_from?: string;
  vod_play_url?: string;
  vod_time?: string;
}

export interface VodListResp {
  code?: number;
  msg?: string;
  page?: number | string;
  pagecount?: number | string;
  limit?: number | string;
  total?: number | string;
  list?: VodRawModel[];
}

/* ============================ 业务模型（与 UI 直接交互） ============================ */

/** 影视条目：把 MacCMS 的蛇形字段归一化成 UI 友好的形态 */
export class VodItem {
  /** 归属站点 key */
  siteKey: string = '';
  /** 归属站点名 */
  siteName: string = '';
  /** 站点内唯一 id */
  id: string = '';
  name: string = '';
  pic: string = '';
  remarks: string = '';
  year: string = '';
  area: string = '';
  typeName: string = '';
  score: string = '';
  actor: string = '';
  director: string = '';
  content: string = '';
  /** 播放源名, 以 $$$ 分隔 */
  playFrom: string = '';
  /** 播放地址, 以 $$$ 分隔线路、# 分隔剧集 */
  playUrl: string = '';
}

/** 单集 */
export class EpisodeModel {
  index: number = 0;
  name: string = '';
  url: string = '';
}

/** 一条播放线路 */
export class PlaySourceModel {
  index: number = 0;
  name: string = '';
  episodes: EpisodeModel[] = [];
}

/** 分类（首页页签） */
export class CategoryModel {
  id: string = '';
  name: string = '';
  /** 父分类 id，'' 或 '0' 表示一级分类 */
  pid: string = '';
  /** 二级分类。MacCMS 的父分类多数站点查不到内容，必须下钻到子分类 */
  children: CategoryModel[] = [];
  filters: FilterItemModel[] = [];

  /** 是否叶子分类（叶子才有内容） */
  isLeaf(): boolean {
    return this.children.length === 0;
  }
}

/** 播放历史 / 收藏 */
export class HistoryItem {
  siteKey: string = '';
  vodId: string = '';
  vodName: string = '';
  pic: string = '';
  episodeName: string = '';
  episodeIndex: number = 0;
  sourceIndex: number = 0;
  position: number = 0;
  updatedAt: number = 0;
}
