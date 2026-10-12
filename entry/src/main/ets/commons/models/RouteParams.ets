import { VodItem } from './TvBoxModels';

/**
 * 路由参数模型。
 * router.pushUrl({ url, params }) 的 params 是 Object，接收端用 as 断言成具体类型即可。
 */

export class DetailParams {
  vod: VodItem = new VodItem();
}

export class PlayerParams {
  vod: VodItem = new VodItem();
  sourceIndex: number = 0;
  /** 线路名：线路会被 sortByPlayability 重排，收到名字才能可靠对齐 */
  sourceName: string = '';
  episodeIndex: number = 0;
  /** 续播位置（毫秒），0 表示从头播 */
  positionMs: number = 0;
  /**
   * 强制横屏进入。
   * 详情页内嵌小窗点「放大」时置 true —— 用户点放大就是要大屏看，
   * 不该被设置里的「进入播放页默认全屏」关掉。
   */
  forceLandscape: boolean = false;
}

export class SnifferParams {
  /** 需要嗅探的网页地址 */
  targetUrl: string = '';
  /** 带上页面来源，规避部分站点的 Referer 防盗链 */
  referer: string = '';
  /** 嗅探结果回传用的标记 */
  requestCode: number = 0;
}

/** 嗅探结果通过 AppStorage 回传（router 无返回值机制） */
export const SNIFF_RESULT_KEY: string = 'sniff_result_url';
