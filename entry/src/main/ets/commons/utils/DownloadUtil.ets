/*
 * 剧集下载（request.agent 任务式下载）+ 本地片库。
 *
 * == 为什么用 request.agent ==
 * HarmonyOS 里下载文件只有两条正路：
 *   ① `request.downloadFile()`（旧接口，已不推荐）；
 *   ② **`request.agent`（文件传输代理，官方主推）** —— 任务交给系统下载服务，
 *      自带断点续传、失败重试、进度回调，应用被杀掉也不影响已排队的任务。
 * 这里走 ②。
 *
 * == 文件落哪儿（⚠️ 2026-10-12 改过）==
 * 原来用**相对路径** `saveas`，官方规定相对路径落在**应用 cacheDir** —— 问题是
 * cacheDir 会被系统在空间紧张时清掉，用户「下载好的片子过几天就没了」。
 * 现在改成写 **filesDir**（应用私有持久目录）：
 *     <filesDir>/vod_download/<片名>@<集名>.mp4
 * 依据是 SDK 里 `Config.saveas` 的第 3 种形式（API 12 起）：
 *   「application storage path, only the base directory and its subdirectories are supported」，
 * 而 `filesDir` = `/data/storage/el2/base/haps/entry/files` 正好在其下。
 * 万一某些设备拒绝这个形式，`enqueue()` 会**自动回退**到老的相对路径写法，
 * 保证「下载」这件事本身不会因为落盘位置而失败。
 *
 * 三方应用**没有**写公共「下载」目录的权限（`READ_WRITE_DOWNLOAD_DIRECTORY` 是
 * system_basic 级），所以只能落沙箱；文件可用本应用内置的本地播放器打开
 * （见 `features/download/`）。
 *
 * == 已知限制（UI 里如实告诉用户）==
 * 拿到的直链如果是 **m3u8（HLS 分片）**，下下来的是一个播放列表文本而不是完整视频 ——
 * 真正的 HLS 离线需要把 TS 分片全拉下来再合并，不在本次范围内。mp4 直链则是完整文件。
 */
import { common } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Log } from './LogUtil';

const TAG: string = 'DownloadUtil';
/** 沙箱内的下载目录名 */
const DIR: string = 'vod_download';
/** 单批最多下多少集，防止一次把采集站打爆 */
const BATCH_MAX: number = 200;
/**
 * 文件名里片名与集名的分隔符。
 * ⚠️ 刻意不用 `-`：片名本身常带 `-`（「名侦探柯南-剧场版」），分隔符歧义会让
 * 列表页解析出错的片名/集名。`@` 在影视名里基本不出现，且不在文件名非法字符里。
 */
const SEP: string = '@';

/** 本地片库里的一项 */
export class DownloadItem {
  /** 文件名（含扩展名） */
  name: string = '';
  /** 绝对路径（不带 file://） */
  path: string = '';
  /** 字节数 */
  size: number = 0;
  /** 修改时间（ms） */
  mtimeMs: number = 0;
  /** 解析出来的片名 */
  vodName: string = '';
  /** 解析出来的集名 */
  epName: string = '';
  /** HLS 播放列表（m3u8）只能下到列表本身，UI 要给出提示 */
  isPlaylist: boolean = false;
}

export class DownloadUtil {
  /** 本会话内已建的任务（持有引用，避免被回收） */
  private static tasks: request.agent.Task[] = [];
  /** 排队 + 进行中的数量 */
  private static running: number = 0;
  private static done: number = 0;
  private static failed: number = 0;

  /**
   * 进度回调：完成/失败任何一个任务都会调一次，参数是「已完成 / 失败 / 仍在跑」。
   * 调用方在这个回调里刷 UI（详情页小窗顶部的下载胶囊）。
   */
  static onProgress: (done: number, failed: number, running: number) => void = () => {
  };

  static isBusy(): boolean {
    return DownloadUtil.running > 0;
  }

  static doneCount(): number {
    return DownloadUtil.done;
  }

  static failedCount(): number {
    return DownloadUtil.failed;
  }

  /** 重置计数（新一批下载开始时调） */
  static reset(): void {
    DownloadUtil.done = 0;
    DownloadUtil.failed = 0;
  }

  /** 下载目录：应用私有持久目录下的 vod_download（不会像 cacheDir 那样被系统清掉） */
  static dirPath(ctx: common.Context): string {
    return `${ctx.filesDir}/${DIR}`;
  }

  /** 回退目录（相对路径 saveas 落在 cacheDir）。只用于「列文件」时兜底扫一遍 */
  static cacheDirPath(ctx: common.Context): string {
    return `${ctx.cacheDir}/${DIR}`;
  }

  /** 一批最多接受多少集 */
  static maxBatch(): number {
    return BATCH_MAX;
  }

  /**
   * 把一集排进下载队列。
   * @param fileName 目标文件名（不含目录），由 `fileNameOf()` 生成
   * @returns 是否成功创建任务
   */
  static async enqueue(ctx: common.Context, url: string, headers: Record<string, string> | undefined,
    fileName: string): Promise<boolean> {
    if (url.length === 0 || fileName.length === 0) {
      return false;
    }
    await DownloadUtil.ensureDir(ctx);
    // 先用「沙箱绝对路径」（落 filesDir，持久），被拒再退回相对路径（落 cacheDir）
    const ok: boolean = await DownloadUtil.start(ctx, url, headers, fileName, `${DownloadUtil.dirPath(ctx)}/${fileName}`);
    if (ok) {
      return true;
    }
    Log.w(TAG, `absolute saveas rejected, fallback to relative: ${fileName}`);
    return await DownloadUtil.start(ctx, url, headers, fileName, `${DIR}/${fileName}`);
  }

  private static async start(ctx: common.Context, url: string, headers: Record<string, string> | undefined,
    fileName: string, saveas: string): Promise<boolean> {
    try {
      const cfg: request.agent.Config = {
        action: request.agent.Action.DOWNLOAD,
        url: url,
        method: 'GET',
        title: fileName,
        description: '影视观下载',
        // 同名文件直接覆盖：重下同一集不会报 13400002
        overwrite: true,
        saveas: saveas,
        // 打开它才会持续回调 progress（不设只在完成时给一次）
        gauge: true
      };
      if (headers !== undefined) {
        cfg.headers = headers;
      }
      const task: request.agent.Task = await request.agent.create(ctx, cfg);
      DownloadUtil.tasks.push(task);
      DownloadUtil.running = DownloadUtil.running + 1;
      task.on('completed', () => {
        DownloadUtil.done = DownloadUtil.done + 1;
        DownloadUtil.settle();
      });
      task.on('failed', () => {
        DownloadUtil.failed = DownloadUtil.failed + 1;
        DownloadUtil.settle();
      });
      await task.start();
      Log.i(TAG, `enqueue ok ${fileName} -> ${saveas}`);
      return true;
    } catch (e) {
      Log.w(TAG, `enqueue failed ${fileName} (${saveas}): ${JSON.stringify(e)}`);
      return false;
    }
  }

  /** 停掉本会话所有任务（页面销毁时调；已下好的文件保留） */
  static stopAll(): void {
    const list: request.agent.Task[] = DownloadUtil.tasks;
    DownloadUtil.tasks = [];
    for (let i = 0; i < list.length; i++) {
      const t: request.agent.Task = list[i];
      // 任务可能已经结束，stop() 会抛，逐个接住
      t.stop().catch((e: Error) => {
        Log.w(TAG, `stop failed: ${e}`);
      });
    }
    DownloadUtil.running = 0;
  }

  /* ==================== 本地片库 ==================== */

  /**
   * 列出已下载的文件（新的排前面）。
   * 目录不存在时返回空数组，不抛 —— 用户还没下过任何东西是最常见的情况。
   *
   * ⚠️ 两个目录都要扫：主目录是 filesDir 下的，但 `enqueue()` 在绝对路径被拒时会
   *   **回退**到相对路径（落 cacheDir）。只扫 filesDir 的话，那批文件会"下载成功但列表里没有"。
   */
  static async list(ctx: common.Context): Promise<DownloadItem[]> {
    const out: DownloadItem[] = [];
    const seen: string[] = [];
    const dirs: string[] = [DownloadUtil.dirPath(ctx), DownloadUtil.cacheDirPath(ctx)];
    for (let d = 0; d < dirs.length; d++) {
      const dir: string = dirs[d];
      let names: string[] = [];
      try {
        names = await fs.listFile(dir);
      } catch (e) {
        Log.i(TAG, `listFile: ${dir} not ready (${e})`);
        continue;
      }
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (seen.indexOf(name) >= 0) {
          continue;
        }
        const full: string = `${dir}/${name}`;
        try {
          const st: fs.Stat = await fs.stat(full);
          if (!st.isFile()) {
            continue;
          }
          const item: DownloadItem = new DownloadItem();
          item.name = name;
          item.path = full;
          item.size = st.size;
          // stat.mtime 单位是**秒**，页面上要毫秒
          item.mtimeMs = st.mtime * 1000;
          const parts: string[] = DownloadUtil.splitName(name);
          item.vodName = parts[0];
          item.epName = parts[1];
          item.isPlaylist = name.toLowerCase().endsWith('.m3u8');
          seen.push(name);
          out.push(item);
        } catch (e) {
          Log.w(TAG, `stat failed ${name}: ${e}`);
        }
      }
    }
    out.sort((a: DownloadItem, b: DownloadItem) => b.mtimeMs - a.mtimeMs);
    return out;
  }

  /** 删除一个已下载文件 */
  static async remove(path: string): Promise<boolean> {
    try {
      await fs.unlink(path);
      Log.i(TAG, `deleted ${path}`);
      return true;
    } catch (e) {
      Log.w(TAG, `delete failed ${path}: ${e}`);
      return false;
    }
  }

  /** 清空整个下载目录 */
  static async clearAll(ctx: common.Context): Promise<number> {
    const items: DownloadItem[] = await DownloadUtil.list(ctx);
    let n: number = 0;
    for (let i = 0; i < items.length; i++) {
      const ok: boolean = await DownloadUtil.remove(items[i].path);
      if (ok) {
        n = n + 1;
      }
    }
    return n;
  }

  /** 供播放器使用：本地沙箱文件要包成 file:// 协议 */
  static fileUrl(path: string): string {
    return path.startsWith('file://') ? path : `file://${path}`;
  }

  /** 可读的体积文案 */
  static sizeText(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    const kb: number = bytes / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(0)} KB`;
    }
    const mb: number = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }

  /* ==================== 文件名 ==================== */

  /**
   * 目标文件名：`片名@集名.扩展名`。
   * 片名里常见的 `/ \ : * ? " < > |` 在文件系统里非法，统一换成 `_`。
   */
  static fileNameOf(vodName: string, epName: string, url: string): string {
    const a: string = DownloadUtil.safe(vodName);
    const b: string = DownloadUtil.safe(epName);
    const base: string = b.length > 0 ? `${a}${SEP}${b}` : a;
    return `${base.length > 0 ? base : 'video'}${DownloadUtil.extOf(url)}`;
  }

  /**
   * 从文件名反解出 [片名, 集名]。
   * 兼容老格式（用 `-` 分隔，本次改版之前下过的文件）。
   */
  private static splitName(name: string): string[] {
    const dot: number = name.lastIndexOf('.');
    const stem: string = dot > 0 ? name.substring(0, dot) : name;
    const at: number = stem.lastIndexOf(SEP);
    if (at > 0) {
      return [stem.substring(0, at), stem.substring(at + 1)];
    }
    const dash: number = stem.lastIndexOf('-');
    if (dash > 0) {
      return [stem.substring(0, dash), stem.substring(dash + 1)];
    }
    return [stem, ''];
  }

  private static async ensureDir(ctx: common.Context): Promise<void> {
    try {
      await fs.mkdir(DownloadUtil.dirPath(ctx));
    } catch (e) {
      // 目录已存在会抛，属于正常情况
    }
  }

  /** 从地址里推扩展名（去掉查询串）；认不出来按 mp4 算 */
  private static extOf(url: string): string {
    const lower: string = url.toLowerCase();
    const q: number = lower.indexOf('?');
    const clean: string = q >= 0 ? lower.substring(0, q) : lower;
    const dot: number = clean.lastIndexOf('.');
    if (dot < 0) {
      return '.mp4';
    }
    const ext: string = clean.substring(dot);
    if (ext.length < 3 || ext.length > 6) {
      return '.mp4';
    }
    // HLS 播放列表本身是文本，扩展名保留 m3u8（让用户知道下到的是播放列表）
    return ext;
  }

  private static safe(s: string): string {
    let out: string = '';
    for (let i = 0; i < s.length; i++) {
      const c: string = s.charAt(i);
      const bad: boolean = c === '/' || c === '\\' || c === ':' || c === '*' || c === '?'
        || c === '"' || c === '<' || c === '>' || c === '|' || c === '\n' || c === '\r';
      out = out + (bad ? '_' : c);
    }
    return out.length > 60 ? out.substring(0, 60) : out;
  }

  private static settle(): void {
    if (DownloadUtil.running > 0) {
      DownloadUtil.running = DownloadUtil.running - 1;
    }
    DownloadUtil.onProgress(DownloadUtil.done, DownloadUtil.failed, DownloadUtil.running);
  }
}
