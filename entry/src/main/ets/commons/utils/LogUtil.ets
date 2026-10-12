import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

/** 统一日志出口，便于上线时一处关闭 */
export class Log {
  static d(tag: string, msg: string): void {
    hilog.debug(DOMAIN, tag, '%{public}s', msg);
  }

  static i(tag: string, msg: string): void {
    hilog.info(DOMAIN, tag, '%{public}s', msg);
  }

  static w(tag: string, msg: string): void {
    hilog.warn(DOMAIN, tag, '%{public}s', msg);
  }

  static e(tag: string, msg: string): void {
    hilog.error(DOMAIN, tag, '%{public}s', msg);
  }
}
