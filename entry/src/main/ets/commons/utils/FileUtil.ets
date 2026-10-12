import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Log } from './LogUtil';

const TAG = 'FileUtil';

/**
 * 应用私有目录下的文本文件读写。
 * 用途：把上一次成功加载的配置缓存到本地，实现「断网也能进首页」。
 * 配置 JSON 动辄几百 KB ~ 数 MB，放 preferences 会拖慢启动，因此落盘到 filesDir。
 */
export class FileUtil {
  static pathOf(ctx: common.Context, name: string): string {
    return `${ctx.filesDir}/${name}`;
  }

  static exists(ctx: common.Context, name: string): boolean {
    try {
      return fs.accessSync(FileUtil.pathOf(ctx, name));
    } catch (e) {
      return false;
    }
  }

  static readText(ctx: common.Context, name: string): string {
    const path: string = FileUtil.pathOf(ctx, name);
    let file: fs.File | undefined = undefined;
    try {
      if (!fs.accessSync(path)) {
        return '';
      }
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(path);
      const size: number = stat.size;
      if (size <= 0) {
        return '';
      }
      const buf: ArrayBuffer = new ArrayBuffer(size);
      const readLen: number = fs.readSync(file.fd, buf);
      if (readLen <= 0) {
        return '';
      }
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buf, 0, readLen));
    } catch (e) {
      Log.w(TAG, `readText ${name} failed: ${JSON.stringify(e)}`);
      return '';
    } finally {
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  static writeText(ctx: common.Context, name: string, text: string): void {
    const path: string = FileUtil.pathOf(ctx, name);
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
    } catch (e) {
      Log.w(TAG, `writeText ${name} failed: ${JSON.stringify(e)}`);
    } finally {
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  static delete(ctx: common.Context, name: string): void {
    try {
      const path: string = FileUtil.pathOf(ctx, name);
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      // ignore
    }
  }

  /** 读取 rawfile 内的文本（内置兜底配置） */
  static readRawFile(ctx: common.Context, name: string): string {
    try {
      const data: Uint8Array = ctx.resourceManager.getRawFileContentSync(name);
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(data);
    } catch (e) {
      Log.e(TAG, `readRawFile ${name} failed: ${JSON.stringify(e)}`);
      return '';
    }
  }

  /** 把配置地址映射成一个安全的缓存文件名 */
  static cacheNameOf(url: string): string {
    let h: number = 0;
    for (let i = 0; i < url.length; i++) {
      h = (h * 31 + url.charCodeAt(i)) | 0;
    }
    const positive: number = h < 0 ? -h : h;
    return `config_cache_${positive}.json`;
  }
}
