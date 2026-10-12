import { ClassModel, SiteModel } from '../../commons/models/TvBoxModels';
import { SiteRouter, VodPage } from './SiteRouter';
import { Store } from '../../commons/utils/StoreUtil';
import { KEY_SITE_KEY } from '../../commons/constants/Constants';
import { Log } from '../../commons/utils/LogUtil';

const TAG = 'SiteProbe';
/** 单次探测最多试几个站（采集站阵亡/被墙是常态，全部探测太费时） */
const PROBE_MAX: number = 6;

/** 站点探测结果 */
export class ProbeResult {
  /** 探测出来真正有数据的站；都没数据时兜底为 sites[0] */
  site: SiteModel | undefined = undefined;
  /** 探测过程中顺手拿到的「最近更新」第一页，可直接复用省一次请求 */
  page: VodPage | undefined = undefined;
  /** 是否拿到了真·有数据的站（false 表示全是兜底/无站） */
  healthy: boolean = false;
}

/**
 * 资源站探测。
 *
 * 首页与推荐页启动时都需要「一个真正有数据的站」：
 *   - 首页要拿它的分类列表；
 *   - 推荐页要拿它的「最近更新」做轮播。
 * 两边各探一次会重复发 6 个请求、还会互相覆盖 KEY_SITE_KEY，
 * 所以这里做成会话内共享的单例：谁先调谁探测，另一个直接等同一个 Promise。
 * 同时顺手缓存站点分类列表（`?ac=list`），两个页面共用一份。
 */
export class SiteProbe {
  private static memo: ProbeResult | undefined = undefined;
  private static inflight: Promise<ProbeResult> | undefined = undefined;
  /** 站点分类缓存：siteKey -> 分类列表 */
  private static classMemo: Map<string, ClassModel[]> = new Map<string, ClassModel[]>();
  /**
   * 代号。配置源变化时自增，让在途的旧探测结果回来时被丢弃
   * （否则会拿着旧配置的站覆盖新配置的探测结果）。
   */
  private static gen: number = 0;

  /** 配置源变化后必须调用，丢掉与旧配置相关的一切缓存 */
  static clear(): void {
    SiteProbe.gen++;
    SiteProbe.memo = undefined;
    SiteProbe.inflight = undefined;
    SiteProbe.classMemo.clear();
  }

  /** 探测出一个有数据的站（会话内只探测一轮） */
  static async pick(sites: SiteModel[]): Promise<ProbeResult> {
    if (SiteProbe.memo !== undefined) {
      return SiteProbe.memo;
    }
    if (SiteProbe.inflight !== undefined) {
      return SiteProbe.inflight;
    }
    const g: number = SiteProbe.gen;
    const job: Promise<ProbeResult> = SiteProbe.doPick(sites);
    SiteProbe.inflight = job;
    try {
      const r: ProbeResult = await job;
      if (g === SiteProbe.gen) {
        SiteProbe.memo = r;
      }
      return r;
    } finally {
      if (g === SiteProbe.gen) {
        SiteProbe.inflight = undefined;
      }
    }
  }

  /**
   * 站点分类列表（`?ac=list`），带缓存。
   * 首页拿它建页签树，推荐页拿它找「电影 / 电视剧」的 type_id。
   */
  static async classes(site: SiteModel): Promise<ClassModel[]> {
    const hit: ClassModel[] | undefined = SiteProbe.classMemo.get(site.key);
    if (hit !== undefined) {
      return hit;
    }
    let list: ClassModel[] = [];
    try {
      list = await SiteRouter.classes(site);
    } catch (e) {
      Log.w(TAG, `classes failed for ${site.name}: ${e}`);
      return [];
    }
    SiteProbe.classMemo.set(site.key, list);
    return list;
  }

  private static async doPick(sites: SiteModel[]): Promise<ProbeResult> {
    const out: ProbeResult = new ProbeResult();
    if (sites.length === 0) {
      return out;
    }

    const saved: string = await Store.getString(KEY_SITE_KEY, '');
    // 上次验证过的站点排最前，其次按配置顺序
    const order: SiteModel[] = [];
    for (let i = 0; i < sites.length; i++) {
      if (saved.length > 0 && sites[i].key === saved) {
        order.push(sites[i]);
        break;
      }
    }
    for (let i = 0; i < sites.length && order.length < PROBE_MAX; i++) {
      if (sites[i].key !== saved) {
        order.push(sites[i]);
      }
    }

    const tasks: Promise<VodPage>[] = [];
    for (let i = 0; i < order.length; i++) {
      tasks.push(SiteRouter.latest(order[i], 1));
    }
    let pages: VodPage[] = [];
    try {
      pages = await Promise.all(tasks);
    } catch (e) {
      Log.w(TAG, `probe failed: ${e}`);
    }
    for (let i = 0; i < pages.length && i < order.length; i++) {
      if (pages[i].ok && pages[i].items.length > 0) {
        out.site = order[i];
        out.page = pages[i];
        out.healthy = true;
        Log.i(TAG, `picked site: ${order[i].name} (${order[i].key}) items=${pages[i].items.length}`);
        if (saved !== order[i].key) {
          await Store.putString(KEY_SITE_KEY, order[i].key);
        }
        return out;
      }
      Log.w(TAG, `probe skip ${order[i].name}: ${pages[i].error}`);
    }
    // 全都没数据：仍然用第一个站，让用户能看到具体错误
    out.site = sites[0];
    Log.w(TAG, `no healthy site, fallback to ${sites[0].name}`);
    return out;
  }
}
