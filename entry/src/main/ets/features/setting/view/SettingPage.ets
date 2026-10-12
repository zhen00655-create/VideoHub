import { common } from '@kit.AbilityKit';
import { Want } from '@kit.AbilityKit';
import { AppTheme, ThemeMode } from '../../../commons/theme/AppTheme';
import { AppSettings, HISTORY_OPTIONS, PAGE_SIZE_OPTIONS, RECONNECT_OPTIONS, SPEED_OPTIONS }
  from '../../../commons/utils/SettingsUtil';
import { BackupUtil, RestoreResult } from '../../../commons/utils/BackupUtil';
import { PlayDataStore } from '../../../commons/utils/PlayDataStore';
import { ConfigManager } from '../../source/ConfigLoader';
import { Store } from '../../../commons/utils/StoreUtil';
import { KEY_CONFIG_URL } from '../../../commons/constants/Constants';
import { Log } from '../../../commons/utils/LogUtil';

const TAG = 'SettingPage';
const PAD: number = AppTheme.PAGE_PADDING;

/** 展开中的选项组，避免同时铺开好几组选项 */
const EXP_NONE: string = '';
const EXP_HISTORY: string = 'history';
const EXP_PAGE: string = 'page';
const EXP_SPEED: string = 'speed';
const EXP_RECONNECT: string = 'reconnect';

/** 主题选项文案。下标与 ThemeMode 的枚举值严格对应：0=黑夜，1=白天 */
const THEME_LABELS: string[] = ['黑夜模式', '白天模式'];

/** 设置项行（右侧可带当前值与箭头） */
@Component
struct SettingRow {
  @Prop title: string = '';
  @Prop desc: string = '';
  @Prop value: string = '';
  @Prop danger: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Row() {
      Column({ space: 3 }) {
        Text(this.title)
          .fontSize(14)
          .fontColor(this.danger ? AppTheme.ACCENT : AppTheme.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.desc.length > 0) {
          Text(this.desc)
            .fontSize(11)
            .fontColor(AppTheme.TEXT_TERTIARY)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.value.length > 0) {
        Text(this.value)
          .fontSize(12)
          .fontColor(AppTheme.TEXT_SECONDARY)
          .margin({ right: 6 })
      }
      Text('›')
        .fontSize(18)
        .fontColor(AppTheme.TEXT_TERTIARY)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 开关行 */
@Component
struct SettingSwitch {
  @Prop title: string = '';
  @Prop desc: string = '';
  @Prop isOn: boolean = false;
  onChange: (v: boolean) => void = () => {
  };

  build() {
    Row() {
      Column({ space: 3 }) {
        Text(this.title)
          .fontSize(14)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .width('100%')
        if (this.desc.length > 0) {
          Text(this.desc)
            .fontSize(11)
            .fontColor(AppTheme.TEXT_TERTIARY)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(AppTheme.ACCENT)
        .onChange((v: boolean) => {
          this.onChange(v);
        })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }
}

/**
 * 一组可选项（倍速 / 条数 / 重连次数共用）。
 *
 * 做成独立 @Component 而不是 @Builder：@Builder 里嵌 ForEach + onClick 的
 * 双层箭头会触发 es2abc 的 "An arrow function cannot have a 'this' parameter"。
 */
@Component
struct SettingChips {
  @Prop labels: string[] = [];
  @Prop selectedIndex: number = -1;
  onPick: (index: number) => void = () => {
  };

  build() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.labels, (label: string, idx: number) => {
        Text(label)
          .fontSize(12)
          .fontColor(idx === this.selectedIndex ? '#FFFFFF' : AppTheme.TEXT_SECONDARY)
          .backgroundColor(idx === this.selectedIndex ? AppTheme.ACCENT : AppTheme.CARD)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(AppTheme.RADIUS_PILL)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.onPick(idx);
          })
      }, (label: string, idx: number) => `chip_${idx}_${label}`)
    }
    .width('100%')
    .padding({ bottom: 6 })
  }
}

/**
 * 设置页（首页右上角齿轮进入）。
 *
 * 分组：播放器 / 首页与数据源 / 观看历史 / 网络 / 数据备份 / 其他。
 */
@Entry
@Component
struct SettingPage {
  @StorageProp('safeTopPx') safeTopPx: number = 0;

  @State maxHistory: number = 100;
  @State pageSize: number = 20;
  @State defaultSpeed: number = 1.0;
  @State autoNext: boolean = true;
  @State reconnectTimes: number = 1;
  @State autoFullscreen: boolean = true;
  @State expand: string = EXP_NONE;
  @State busy: boolean = false;
  /** 订阅 AppStorage（由 ConfigManager 统一发布），与首页/源管理页保持同一口径 */
  @StorageProp('usableSiteCount') siteCount: number = 0;
  /** 主题模式：0 黑夜 / 1 白天 */
  @State themeMode: number = 0;
  /**
   * 订阅主题版本号。AppTheme 的 getter 不是响应式的，
   * 主题切换后必须靠这个值把本页标记为脏，否则本页不会跟着变色。
   */
  @StorageProp('themeVersion') themeVersion: number = 0;
  @State blockedCount: number = 0;
  @State historyCount: number = 0;
  @State favoriteCount: number = 0;
  @State curSourceDesc: string = '';

  aboutToAppear(): void {
    this.load();
  }

  build() {
    Column() {
      /* 顶部栏 */
      Row() {
        Text('‹')
          .fontSize(28)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .width(38)
          .height(44)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })
        Text('设置')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .layoutWeight(1)
      }
      .width('100%')
      .height(48)

      List() {
        /* ==================== 播放器 ==================== */
        ListItem() {
          Text('播放器')
            .fontSize(13)
            .fontColor(AppTheme.TEXT_SECONDARY)
            .width('100%')
            .margin({ top: 6, bottom: 2 })
        }

        ListItem() {
          SettingRow({
            title: '默认倍速',
            desc: '进入播放页时的初始播放速度',
            value: `${this.defaultSpeed}x`,
            onTap: () => {
              this.toggleExpand(EXP_SPEED);
            }
          })
        }

        if (this.expand === EXP_SPEED) {
          ListItem() {
            SettingChips({
              labels: this.labelsOf(SPEED_OPTIONS, 'x', ''),
              selectedIndex: this.indexOf(SPEED_OPTIONS, this.defaultSpeed),
              onPick: (i: number) => {
                this.applyChoice(EXP_SPEED, SPEED_OPTIONS[i]);
              }
            })
          }
        }

        ListItem() {
          SettingSwitch({
            title: '播完自动下一集',
            desc: '一集播完自动切换到下一集（播放页也可临时切换）',
            isOn: this.autoNext,
            onChange: (v: boolean) => {
              this.autoNext = v;
              AppSettings.current().autoNext = v;
              this.persist();
            }
          })
        }

        ListItem() {
          SettingRow({
            title: '播放失败自动重连',
            desc: '片源卡顿或中断时自动重试，0 次为关闭',
            value: this.reconnectTimes === 0 ? '关闭' : `${this.reconnectTimes} 次`,
            onTap: () => {
              this.toggleExpand(EXP_RECONNECT);
            }
          })
        }

        if (this.expand === EXP_RECONNECT) {
          ListItem() {
            SettingChips({
              labels: this.labelsOf(RECONNECT_OPTIONS, ' 次', '关闭'),
              selectedIndex: this.indexOf(RECONNECT_OPTIONS, this.reconnectTimes),
              onPick: (i: number) => {
                this.applyChoice(EXP_RECONNECT, RECONNECT_OPTIONS[i]);
              }
            })
          }
        }

        ListItem() {
          SettingSwitch({
            title: '进入播放页默认全屏',
            desc: '关闭后进入播放页先竖屏，可手动全屏',
            isOn: this.autoFullscreen,
            onChange: (v: boolean) => {
              this.autoFullscreen = v;
              AppSettings.current().autoFullscreen = v;
              this.persist();
            }
          })
        }

        ListItem() {
          Column({ space: 4 }) {
            Text('解码器 / 渲染方式')
              .fontSize(14)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
            Text('HarmonyOS 播放链路使用系统 AVPlayer + XComponent(Surface) 硬解渲染，'
              + '不支持 IJK / EXO / 软解切换（这两个是 Android 端方案）。')
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .lineHeight(17)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 12, bottom: 12 })
        }

        ListItem() {
          Divider().color(AppTheme.LINE).margin({ top: 6, bottom: 6 })
        }

        /* ==================== 主题 ==================== */
        ListItem() {
          Text('主题')
            .fontSize(13)
            .fontColor(AppTheme.TEXT_SECONDARY)
            .width('100%')
            .margin({ top: 6, bottom: 2 })
        }

        ListItem() {
          Column({ space: 4 }) {
            Text('白天 / 黑夜模式')
              .fontSize(14)
              .fontColor(AppTheme.TEXT_PRIMARY)
              .width('100%')
            Text('白天模式为亮堂的浅色界面；黑夜模式沿用原来的深色夜空渐变。播放页不受主题影响，保持黑底。')
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .lineHeight(17)
              .width('100%')
            SettingChips({
              labels: THEME_LABELS,
              selectedIndex: this.themeMode,
              onPick: (i: number) => {
                this.applyTheme(i);
              }
            })
              .margin({ top: 6 })
            Text('切换主题后软件会重新加载')
              .fontSize(10)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .width('100%')
              .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 12, bottom: 12 })
        }

        /* ==================== 首页与数据源 ==================== */
        ListItem() {
          Text('首页与数据源')
            .fontSize(13)
            .fontColor(AppTheme.TEXT_SECONDARY)
            .width('100%')
            .margin({ top: 6, bottom: 2 })
        }

        ListItem() {
          SettingRow({
            title: '每页条数',
            desc: '分类列表每页拉取的影片数量',
            value: `${this.pageSize} 条`,
            onTap: () => {
              this.toggleExpand(EXP_PAGE);
            }
          })
        }

        if (this.expand === EXP_PAGE) {
          ListItem() {
            SettingChips({
              labels: this.labelsOf(PAGE_SIZE_OPTIONS, ' 条', ''),
              selectedIndex: this.indexOf(PAGE_SIZE_OPTIONS, this.pageSize),
              onPick: (i: number) => {
                this.applyChoice(EXP_PAGE, PAGE_SIZE_OPTIONS[i]);
              }
            })
          }
        }

        ListItem() {
          SettingRow({
            title: '数据源显示',
            desc: '管理站点启用状态，被禁用的站点不会出现在首页与搜索',
            value: `可用 ${this.siteCount} · 禁用 ${this.blockedCount}`,
            onTap: () => {
              this.goSource();
            }
          })
        }

        ListItem() {
          SettingRow({
            title: '配置与线路',
            desc: '切换内置源 / 网络源 / 多仓线路',
            value: this.curSourceDesc,
            onTap: () => {
              this.goSource();
            }
          })
        }

        ListItem() {
          Divider().color(AppTheme.LINE).margin({ top: 6, bottom: 6 })
        }

        /* ==================== 观看历史 ==================== */
        ListItem() {
          Text('观看历史')
            .fontSize(13)
            .fontColor(AppTheme.TEXT_SECONDARY)
            .width('100%')
            .margin({ top: 6, bottom: 2 })
        }

        ListItem() {
          SettingRow({
            title: '保存条数',
            desc: '超出后自动丢弃最早的记录',
            value: `${this.maxHistory} 条`,
            onTap: () => {
              this.toggleExpand(EXP_HISTORY);
            }
          })
        }

        if (this.expand === EXP_HISTORY) {
          ListItem() {
            SettingChips({
              labels: this.labelsOf(HISTORY_OPTIONS, ' 条', ''),
              selectedIndex: this.indexOf(HISTORY_OPTIONS, this.maxHistory),
              onPick: (i: number) => {
                this.applyChoice(EXP_HISTORY, HISTORY_OPTIONS[i]);
              }
            })
          }
        }

        ListItem() {
          SettingRow({
            title: '清空播放历史',
            desc: `当前 ${this.historyCount} 条记录，清空后续播进度一并丢失`,
            value: '',
            danger: true,
            onTap: () => {
              this.clearHistory();
            }
          })
        }

        ListItem() {
          SettingRow({
            title: '清空收藏',
            desc: `当前 ${this.favoriteCount} 部收藏`,
            value: '',
            danger: true,
            onTap: () => {
              this.clearFavorites();
            }
          })
        }

        ListItem() {
          Divider().color(AppTheme.LINE).margin({ top: 6, bottom: 6 })
        }

        /* ==================== 网络 ==================== */
        ListItem() {
          Text('网络')
            .fontSize(13)
            .fontColor(AppTheme.TEXT_SECONDARY)
            .width('100%')
            .margin({ top: 6, bottom: 2 })
        }

        ListItem() {
          Column({ space: 4 }) {
            Text('安全 DNS')
              .fontSize(14)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
            Text('HarmonyOS 未开放应用级 DoH 配置，本版本跟随系统 DNS；'
              + '若某些采集站域名被污染，可在「源管理」里换用其它镜像地址（如 jsDelivr）。')
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .lineHeight(17)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 12, bottom: 12 })
        }

        ListItem() {
          Divider().color(AppTheme.LINE).margin({ top: 6, bottom: 6 })
        }

        /* ==================== 数据备份 ==================== */
        ListItem() {
          Text('数据备份与还原')
            .fontSize(13)
            .fontColor(AppTheme.TEXT_SECONDARY)
            .width('100%')
            .margin({ top: 6, bottom: 2 })
        }

        ListItem() {
          Column({ space: 4 }) {
            Text('把配置地址、播放历史、收藏、站点禁用与设置项打包成 JSON 文件，换设备时可直接还原。')
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .lineHeight(17)
              .width('100%')
            Row({ space: 10 }) {
              Text(this.busy ? '处理中…' : '导出备份')
                .fontSize(13)
                .fontColor('#FFFFFF')
                .backgroundColor(this.busy ? AppTheme.TEXT_TERTIARY : AppTheme.ACCENT)
                .padding({ left: 18, right: 18, top: 9, bottom: 9 })
                .borderRadius(AppTheme.RADIUS_PILL)
                .onClick(() => {
                  this.exportBackup();
                })
              Text('从备份还原')
                .fontSize(13)
                .fontColor(AppTheme.TEXT_PRIMARY)
                .backgroundColor(AppTheme.SURFACE)
                .padding({ left: 18, right: 18, top: 9, bottom: 9 })
                .borderRadius(AppTheme.RADIUS_PILL)
                .onClick(() => {
                  this.restoreBackup();
                })
            }
            .width('100%')
            .margin({ top: 8 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 8, bottom: 12 })
        }

        /* ==================== 其他 ==================== */
        ListItem() {
          Divider().color(AppTheme.LINE).margin({ top: 6, bottom: 6 })
        }

        ListItem() {
          Text('其他')
            .fontSize(13)
            .fontColor(AppTheme.TEXT_SECONDARY)
            .width('100%')
            .margin({ top: 6, bottom: 2 })
        }

        ListItem() {
          Column({ space: 4 }) {
            Text('界面语言')
              .fontSize(14)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
            Text('当前仅提供简体中文。')
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 12, bottom: 12 })
        }

        ListItem() {
          Column({ space: 4 }) {
            Text('画中画 / 小窗')
              .fontSize(14)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
            Text('画中画需要系统 PiP 窗口能力与应用内声明，本版本未开放；'
              + '播放页支持竖屏小窗模式（点右上角全屏按钮切换）。')
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .lineHeight(17)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 12, bottom: 12 })
        }

        ListItem() {
          Column({ space: 4 }) {
            Text('网盘挂载')
              .fontSize(14)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
            Text('WebDAV / Alist 挂载依赖第三方网盘协议栈，本版本尚未开放。')
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 12, bottom: 12 })
        }

        ListItem() {
          Column({ space: 6 }) {
            Text('关于')
              .fontSize(12)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
            Text('影视仓 · HarmonyOS NEXT ArkTS\n'
              + '本应用本身不提供任何影视内容，仅作为第三方 JSON 配置源的通用客户端：\n'
              + '配置、解析规则与播放地址均来自用户自行添加的源。\n'
              + 'P2P 加速与 XWalkView 为 Android 端方案，鸿蒙端不适用。')
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .lineHeight(18)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 14, bottom: 36 })
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: PAD, right: PAD })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [
        [AppTheme.BG_GRAD_TOP, 0.0],
        [AppTheme.BG_GRAD_MID, 0.5],
        [AppTheme.BG_GRAD_BOTTOM, 1.0]
      ]
    })
    .padding({ top: this.getUIContext().px2vp(this.safeTopPx) })
  }

  /* ==================== 选项行 ==================== */

  /** 生成选项标签：值为 0 且给了 zeroLabel 时显示成「关闭」 */
  private labelsOf(values: number[], unit: string, zeroLabel: string): string[] {
    const out: string[] = [];
    for (let i = 0; i < values.length; i++) {
      if (values[i] === 0 && zeroLabel.length > 0) {
        out.push(zeroLabel);
      } else {
        out.push(`${values[i]}${unit}`);
      }
    }
    return out;
  }

  private indexOf(values: number[], cur: number): number {
    for (let i = 0; i < values.length; i++) {
      if (values[i] === cur) {
        return i;
      }
    }
    return -1;
  }

  /** 选中某一项后写回设置并收起选项 */
  private applyChoice(kind: string, value: number): void {
    const s = AppSettings.current();
    if (kind === EXP_SPEED) {
      this.defaultSpeed = value;
      s.defaultSpeed = value;
    } else if (kind === EXP_PAGE) {
      this.pageSize = value;
      s.pageSize = value;
    } else if (kind === EXP_RECONNECT) {
      this.reconnectTimes = value;
      s.reconnectTimes = value;
    } else {
      this.maxHistory = value;
      s.maxHistory = value;
    }
    this.expand = EXP_NONE;
    this.persist();
  }

  private toggleExpand(which: string): void {
    this.expand = this.expand === which ? EXP_NONE : which;
  }

  /**
   * 切换主题。
   * 三件事必须一起做：写回设置（持久化）→ 通知 AppTheme 换色板（并 bump themeVersion
   * 让各订阅页面重渲染）→ 更新本页选中态。
   *
   * ⚠️ 实时刷新在跨页场景下不可靠：设置页是 @Entry 独立路由页，切换后底下的
   *    Index / 三个页签页都还在路由栈里未被销毁，而它们依赖 themeVersion 变化才重绘；
   *    离屏路由页的 @StorageProp 更新会被框架节流/跳过，导致「切了要重启才全变色」。
   *    所以切完主题后**直接拉起自重启**（terminateSelf + startAbility 自己），
   *    让整个 App 用新色板从头渲染，保证 100% 一致。旁边配小字提醒。
   */
  private applyTheme(mode: number): void {
    const next: number = mode === ThemeMode.Light ? ThemeMode.Light : ThemeMode.Dark;
    if (next === this.themeMode) {
      return;
    }
    this.themeMode = next;
    AppSettings.current().themeMode = next;
    AppTheme.setMode(next);
    this.persist();
    Log.i(TAG, `theme switched to ${next === ThemeMode.Light ? 'light' : 'dark'}, will restart`);
    this.confirmRestart();
  }

  /**
   * 切完主题弹确认框，确认后自重启。
   * 用 AlertDialog 而不是直接 terminateSelf：给用户一个「正在重启」的预期，
   * 否则点击瞬间 App 消失会很突兀。
   */
  private confirmRestart(): void {
    AlertDialog.show({
      title: '主题已切换',
      message: '为完整应用新配色，需要重新加载软件。',
      primaryButton: {
        value: '立即重新加载',
        action: () => {
          this.restartApp();
        }
      },
      secondaryButton: {
        value: '稍后',
        action: () => {
        }
      },
      alignment: DialogAlignment.Center
    });
  }

  /** 自重启：先 terminateSelf，成功后 startAbility 拉起自己（鸿蒙官方推荐的自重启套路） */
  private restartApp(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.terminateSelf().then(() => {
        const want: Want = {
          bundleName: 'com.wsing.phonetv',
          abilityName: 'EntryAbility'
        };
        ctx.startAbility(want).catch((err: Error) => {
          Log.e(TAG, `restart startAbility failed: ${err}`);
        });
      }).catch((err: Error) => {
        Log.e(TAG, `restart terminateSelf failed: ${err}`);
      });
    } catch (e) {
      Log.e(TAG, `restartApp failed: ${e}`);
    }
  }

  /* ==================== 逻辑 ==================== */

  private async load(): Promise<void> {
    const s = await AppSettings.ensure();
    this.maxHistory = s.maxHistory;
    this.pageSize = s.pageSize;
    this.defaultSpeed = s.defaultSpeed;
    this.autoNext = s.autoNext;
    this.reconnectTimes = s.reconnectTimes;
    this.autoFullscreen = s.autoFullscreen;

    const cfg = ConfigManager.get();
    // siteCount 已改为 @StorageProp 订阅，这里不再手动同步
    this.themeMode = s.themeMode;
    this.blockedCount = cfg.getBlockedKeys().length;
    this.curSourceDesc = cfg.usingBuiltin
      ? '内置源'
      : (cfg.currentWareIndex >= 0 && cfg.currentWareIndex < cfg.wares.length
        ? cfg.wares[cfg.currentWareIndex].name
        : (cfg.sourceDesc.length > 0 ? cfg.sourceDesc : '网络源'));

    try {
      this.historyCount = (await PlayDataStore.loadHistory()).length;
      this.favoriteCount = (await PlayDataStore.loadFavorites()).length;
    } catch (e) {
      Log.w(TAG, `count failed: ${e}`);
    }
  }

  private persist(): void {
    AppSettings.save().catch((e: Error) => {
      Log.w(TAG, `persist failed: ${e}`);
    });
  }

  private async clearHistory(): Promise<void> {
    await PlayDataStore.clearHistory();
    this.historyCount = 0;
    this.bumpHistory();
    this.toast('播放历史已清空');
  }

  private async clearFavorites(): Promise<void> {
    await PlayDataStore.clearFavorites();
    this.favoriteCount = 0;
    this.bumpHistory();
    this.toast('收藏已清空');
  }

  private async exportBackup(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const name: string = await BackupUtil.exportTo(ctx);
      this.busy = false;
      this.toast(name.length > 0 ? `已导出 ${name}` : '已取消导出');
    } catch (e) {
      this.busy = false;
      this.toast(`导出异常：${e}`);
    }
  }

  private async restoreBackup(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const res: RestoreResult = await BackupUtil.restoreFrom(ctx);
      this.busy = false;
      this.toast(res.message);
      if (!res.ok) {
        return;
      }
      await this.reloadConfig(ctx);
      await this.load();
      this.bumpHistory();
      AppStorage.setOrCreate('configVersion', this.bumpConfig());
    } catch (e) {
      this.busy = false;
      this.toast(`还原异常：${e}`);
    }
  }

  /** 还原后让 ConfigManager 按新的配置地址重新加载 */
  private async reloadConfig(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const url: string = await Store.getString(KEY_CONFIG_URL, '');
      if (url.length === 0) {
        await ConfigManager.get().useBuiltin(ctx);
      } else if (url.startsWith(ConfigManager.LOCAL_PREFIX)) {
        // 本地导入配置的正文不在备份里，需要用户重新选文件
        await ConfigManager.get().loadBuiltin(ctx);
        this.toast('本地导入的配置正文未备份，请到源管理重新导入');
      } else {
        await ConfigManager.get().loadRoot(url, ctx, false);
      }
    } catch (e) {
      Log.w(TAG, `reloadConfig failed: ${e}`);
    }
  }

  private bumpHistory(): void {
    const v: number | undefined = AppStorage.get<number>('historyVersion');
    AppStorage.setOrCreate('historyVersion', (v === undefined ? 0 : v) + 1);
  }

  private bumpConfig(): number {
    const v: number | undefined = AppStorage.get<number>('configVersion');
    return (v === undefined ? 0 : v) + 1;
  }

  private goSource(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'features/source/view/SourcePage' }).catch(() => {
      this.toast('无法打开源管理');
    });
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2200 });
    } catch (e) {
      Log.w(TAG, `toast failed: ${e}`);
    }
  }
}
