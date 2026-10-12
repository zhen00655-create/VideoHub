import { EpisodeModel, PlaySourceModel } from '../../commons/models/TvBoxModels';
import { UrlUtil } from '../../commons/utils/UrlUtil';

/**
 * 播放地址解析
 *
 * MacCMS / TVBox 的 vod_play_url 结构（两级分隔）：
 *   线路之间: $$$
 *   剧集之间: #
 *   名称与地址之间: $
 *
 * 例：
 *   vod_play_from = "HD$$$超清"
 *   vod_play_url  = "第01集$http://a/1.m3u8#第02集$http://a/2.m3u8$$$第01集$http://b/1.m3u8"
 *
 * 注意：地址本身可能带 query（含 = & ?），因此只用「第一个 $」切分，不能用 split 全拆。
 */
export class PlayUrlParser {
  static parse(vodPlayFrom: string, vodPlayUrl: string): PlaySourceModel[] {
    const result: PlaySourceModel[] = [];
    if (vodPlayUrl === undefined || vodPlayUrl.length === 0) {
      return result;
    }

    const urlBlocks: string[] = vodPlayUrl.split('$$$');
    const fromList: string[] = (vodPlayFrom === undefined || vodPlayFrom.length === 0)
      ? [] : vodPlayFrom.split('$$$');

    for (let i = 0; i < urlBlocks.length; i++) {
      const block: string = urlBlocks[i];
      if (block === undefined || block.trim().length === 0) {
        continue;
      }
      const src: PlaySourceModel = new PlaySourceModel();
      src.index = result.length;
      if (i < fromList.length && fromList[i].trim().length > 0) {
        src.name = fromList[i].trim();
      } else {
        src.name = `线路${result.length + 1}`;
      }
      src.episodes = PlayUrlParser.parseEpisodes(block);
      if (src.episodes.length > 0) {
        result.push(src);
      }
    }

    return result;
  }

  /** 解析单条线路里的剧集列表 */
  static parseEpisodes(block: string): EpisodeModel[] {
    const episodes: EpisodeModel[] = [];
    const parts: string[] = block.split('#');
    for (let i = 0; i < parts.length; i++) {
      const raw: string = parts[i] === undefined ? '' : parts[i].trim();
      if (raw.length === 0) {
        continue;
      }
      const ep: EpisodeModel = new EpisodeModel();
      ep.index = episodes.length;

      const dollar: number = raw.indexOf('$');
      if (dollar > 0 && dollar < raw.length - 1) {
        ep.name = raw.substring(0, dollar).trim();
        ep.url = raw.substring(dollar + 1).trim();
      } else if (dollar === 0) {
        ep.url = raw.substring(1).trim();
        ep.name = '';
      } else {
        // 没有名称，整段就是地址
        ep.url = raw;
        ep.name = '';
      }

      if (ep.url.length === 0) {
        continue;
      }
      if (ep.name.length === 0) {
        const fn: string = UrlUtil.fileNameOf(ep.url);
        ep.name = fn.length > 0 ? fn : `第${episodes.length + 1}集`;
      }
      episodes.push(ep);
    }
    return episodes;
  }

  /**
   * 判断该线路是否「大概率可直连播放」。
   * 优先级：m3u8 > mp4/flv > 其他；网页链接需要走解析器。
   */
  static directPlayableRatio(episodes: EpisodeModel[]): number {
    if (episodes.length === 0) {
      return 0;
    }
    let direct: number = 0;
    for (let i = 0; i < episodes.length; i++) {
      if (UrlUtil.isMediaUrl(episodes[i].url)) {
        direct++;
      }
    }
    return direct / episodes.length;
  }

  /** 线路排序：直连比例高的排前面（TVBox 同款策略） */
  static sortByPlayability(sources: PlaySourceModel[]): PlaySourceModel[] {
    const copy: PlaySourceModel[] = sources.slice();
    copy.sort((a: PlaySourceModel, b: PlaySourceModel) => {
      const ra: number = PlayUrlParser.directPlayableRatio(a.episodes);
      const rb: number = PlayUrlParser.directPlayableRatio(b.episodes);
      if (ra === rb) {
        return b.episodes.length - a.episodes.length;
      }
      return rb > ra ? 1 : -1;
    });
    for (let i = 0; i < copy.length; i++) {
      copy[i].index = i;
    }
    return copy;
  }
}
