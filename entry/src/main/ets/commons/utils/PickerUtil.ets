import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './LogUtil';

const TAG = 'PickerUtil';

/**
 * 本地文件选择 / 保存。
 *
 * 用系统 DocumentViewPicker 而不是直接申请受限权限：
 * 用户自己挑文件，App 拿到的是临时可读写的 uri，不需要任何存储权限。
 * 取消选择在部分设备上是「抛异常」而不是「返回空数组」，所以两种情况都要吃掉。
 */
export class PickerUtil {

  /** 选择一个本地文件并读出文本；返回 '' 表示取消或失败 */
  static async pickText(ctx: common.UIAbilityContext, suffixes: string[]): Promise<string> {
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      if (suffixes !== undefined && suffixes.length > 0) {
        options.fileSuffixFilters = suffixes;
      }
      const dp: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await dp.select(options);
      if (uris === undefined || uris === null || uris.length === 0) {
        return '';
      }
      return PickerUtil.readUri(uris[0]);
    } catch (e) {
      const err = e as BusinessError;
      Log.w(TAG, `pickText cancelled/failed: ${err.code} ${err.message}`);
      return '';
    }
  }

  /** 读取一个 uri 的文本内容 */
  static readUri(uri: string): string {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const size: number = stat.size;
      if (size <= 0) {
        return '';
      }
      const buf: ArrayBuffer = new ArrayBuffer(size);
      const readLen: number = fileIo.readSync(file.fd, buf);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buf.slice(0, readLen)));
    } catch (e) {
      const err = e as BusinessError;
      Log.e(TAG, `readUri failed: ${err.code} ${err.message}`);
      return '';
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          Log.w(TAG, `closeSync failed: ${e}`);
        }
      }
    }
  }

  /** 让用户选择保存位置并写入文本；返回 '' 表示取消或失败 */
  static async saveText(ctx: common.UIAbilityContext, suggestedName: string, content: string): Promise<string> {
    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [suggestedName];
      const dp: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await dp.save(options);
      if (uris === undefined || uris === null || uris.length === 0) {
        return '';
      }
      const uri: string = uris[0];
      const file: fileIo.File = fileIo.openSync(uri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
      fileIo.closeSync(file);
      Log.i(TAG, `saved: ${uri}`);
      return uri;
    } catch (e) {
      const err = e as BusinessError;
      Log.w(TAG, `saveText cancelled/failed: ${err.code} ${err.message}`);
      return '';
    }
  }
}
