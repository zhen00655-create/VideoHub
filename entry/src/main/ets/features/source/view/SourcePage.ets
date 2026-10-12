import { common } from '@kit.AbilityKit';
import { SiteModel } from '../../../commons/models/TvBoxModels';
import { ConfigManager, WareInfo } from '../../source/ConfigLoader';
import { AppTheme } from '../../../commons/theme/AppTheme';
import { PRESET_CONFIG_URLS } from '../../../commons/constants/Constants';
import { PickerUtil } from '../../../commons/utils/PickerUtil';
import { Log } from '../../../commons/utils/LogUtil';

const TAG = 'SourcePage';
const PAD: number = AppTheme.PAGE_PADDING;

/* ---------- 操作按钮统一样式 ----------
 * 之前「重新加载 / 加载 / 启用 / 选择本地配置」四个按钮各写各的 padding 与圆角，
 * 结果高低不齐（加载 上下 10、启用 上下 6、重新加载 上下 8），字号也散落在 11~13。
 * 统一到这里，改一处四处一起变。
 */
const BTN_FS: number = 13;
const BTN_H: number = 38;
const BTN_PAD_H: number = 16;
/** 高度的一半 → 正圆胶囊 */
const BTN_RADIUS: number = BTN_H / 2;
const BTN_TEXT: string = '#FFFFFF';

@Entry
@Component
struct SourcePage {
  @StorageProp('safeTopPx') safeTopPx: number = 0;

  @State wares: WareInfo[] = [];
  @State curWare: number = -1;
  /**
   * 站点数量订阅 AppStorage（由 ConfigManager 在站点变化时发布），
   * 与首页顶部副标题共用同一份值 —— 原来这里是 @State + onPageShow 主动同步，
   * 于是两个页面各读各的，出现了「源管理显示有可用源、首页显示 0 个」的不一致。
   */
  @StorageProp('usableSiteCount') siteCount: number = 0;
  @StorageProp('allSiteCount') allCount: number = 0;
  /** 订阅主题版本：AppTheme 的 getter 不是响应式的，主题切换后靠它触发重渲染 */
  @StorageProp('themeVersion') themeVersion: number = 0;
  @State picking: boolean = false;
  @State inputUrl: string = '';
  @State showSites: boolean = false;
  @State curUrl: string = '';
  @State busy: boolean = false;
  /* ---------- 内置源 ---------- */
  @State builtinName: string = '';
  @State builtinSites: SiteModel[] = [];
  @State usingBuiltin: boolean = false;
  @State showBuiltinSites: boolean = false;

  aboutToAppear(): void {
    this.refreshView();
  }

  /**
   * 统一的胶囊操作按钮。四处操作按钮都走这里，保证字号/配色/高度完全一致。
   * @param active false 时置灰（如「使用中」），不再当作可点按钮
   * @param stretch true 时撑满父容器宽度（父容器需要 width('100%')）
   */
  @Builder
  pollBtn(label: string, onTap: () => void, active: boolean, stretch: boolean) {
    Text(label)
      .fontSize(BTN_FS)
      .fontColor(active ? BTN_TEXT : AppTheme.TEXT_TERTIARY)
      .backgroundColor(active ? AppTheme.ACCENT : AppTheme.CARD)
      .height(BTN_H)
      .padding({ left: BTN_PAD_H, right: BTN_PAD_H })
      .borderRadius(BTN_RADIUS)
      .textAlign(TextAlign.Center)
      .layoutWeight(stretch ? 1 : 0)
      .onClick(() => {
        if (active) {
          onTap();
        }
      })
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
        Text('源管理')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .layoutWeight(1)
      }
      .width('100%')
      .height(48)

      List() {
        /* 当前配置 */
        ListItem() {
          Column() {
            Text('当前配置')
              .fontSize(13)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
              .margin({ bottom: 8 })
            Text(this.curUrl.length > 0 ? this.curUrl : '(内置兜底源)')
              .fontSize(12)
              .fontColor(AppTheme.TEXT_PRIMARY)
              .width('100%')
              .padding(10)
              .backgroundColor(AppTheme.CARD)
              .borderRadius(8)
            Row({ space: 10 }) {
              this.pollBtn(this.busy ? '处理中…' : '重新加载', () => {
                this.reloadCurrent();
              }, !this.busy, false)
              Text(`可用源 ${this.siteCount} / 共 ${this.allCount}`)
                .fontSize(12)
                .fontColor(AppTheme.TEXT_TERTIARY)
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 10 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .padding({ bottom: 16 })

        /* 手动输入配置地址 */
        ListItem() {
          Column() {
            Text('添加 / 切换配置源')
              .fontSize(13)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
              .margin({ bottom: 8 })
            Row({ space: 8 }) {
              TextInput({ placeholder: '粘贴 TVBox 单仓/多仓 JSON 地址', text: this.inputUrl })
                .placeholderColor(AppTheme.TEXT_TERTIARY)
                // 提示文案单独调小：.fontSize() 只管输入的字，占位符得用 placeholderFont 才压得住
                .placeholderFont({ size: 11 })
                .fontColor(AppTheme.TEXT_PRIMARY)
                .fontSize(12)
                .backgroundColor(AppTheme.CARD)
                .height(BTN_H)
                .layoutWeight(1)
                .onChange((v: string) => {
                  this.inputUrl = v;
                })
              this.pollBtn('加载', () => {
                this.applyUrl(this.inputUrl);
              }, true, false)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .padding({ bottom: 16 })

        /* ---------- 预置源 · 内置（随包发布，不依赖网络） ---------- */
        ListItem() {
          Column() {
            Row() {
              Text('预置源 · 内置')
                .fontSize(13)
                .fontColor(AppTheme.TEXT_SECONDARY)
                .layoutWeight(1)
              Text(this.showBuiltinSites ? '收起站点' : '查看站点')
                .fontSize(12)
                .fontColor(AppTheme.ACCENT)
                .onClick(() => {
                  this.showBuiltinSites = !this.showBuiltinSites;
                })
            }
            .width('100%')
            .margin({ bottom: 8 })

            Row() {
              Column() {
                Text(this.builtinName)
                  .fontSize(14)
                  .fontColor(this.usingBuiltin ? AppTheme.ACCENT : AppTheme.TEXT_PRIMARY)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(`内置 ${this.builtinSites.length} 个采集站 · 随包发布，无需联网拉配置`)
                  .fontSize(10)
                  .fontColor(AppTheme.TEXT_TERTIARY)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 3 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              /* 卡片右侧不让内边距后，这里补 10 的外边距，保证文字与按钮之间仍有间距 */
              .margin({ right: 10 })

              this.pollBtn(this.usingBuiltin ? '使用中' : '启用', () => {
                this.useBuiltin();
              }, !this.usingBuiltin, false)
            }
            .width('100%')
            /* 右侧不留内边距：「启用」的右边缘直接落在内容区右界，
             * 与上方「加载」按钮对齐成同一条竖线。
             * （原先卡片左右各留 10，导致按钮右边缘比「加载」靠左 10vp） */
            .padding({ top: 10, bottom: 10, left: 10, right: 0 })
            .backgroundColor(AppTheme.CARD)
            .borderRadius(10)
            .onClick(() => {
              this.useBuiltin();
            })

            if (this.showBuiltinSites) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.builtinSites, (s: SiteModel) => {
                  Text(s.name)
                    .fontSize(11)
                    .fontColor(ConfigManager.get().isUsable(s) ? AppTheme.TEXT_SECONDARY : AppTheme.TEXT_TERTIARY)
                    .backgroundColor(AppTheme.CARD)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .borderRadius(AppTheme.RADIUS_PILL)
                    .margin({ right: 8, top: 8 })
                }, (s: SiteModel) => `bs_${s.key}`)
              }
              .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .padding({ bottom: 16 })


        /* 预置源（网络地址） */
        ListItem() {
          Column() {
            Text('预置源 · 网络地址')
              .fontSize(13)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
              .margin({ bottom: 8 })
            ForEach(PRESET_CONFIG_URLS, (u: string) => {
              Text(u)
                .fontSize(11)
                .fontColor(AppTheme.TEXT_TERTIARY)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({ top: 9, bottom: 9, left: 10, right: 10 })
                .backgroundColor(AppTheme.CARD)
                .borderRadius(8)
                .margin({ bottom: 8 })
                .onClick(() => {
                  this.applyUrl(u);
                })
            }, (u: string) => `preset_${u}`)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .padding({ bottom: 16 })


        /* ---------- 本地导入 ---------- */
        ListItem() {
          Column() {
            Text('本地导入')
              .fontSize(13)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
              .margin({ bottom: 8 })
            Row({ space: 10 }) {
              this.pollBtn('选择本地 JSON 配置', () => {
                this.importLocal();
              }, true, true)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .padding({ bottom: 16 })



        /* 多仓线路 */
        if (this.wares.length > 0) {
          ListItem() {
            Text(`配置线路（共 ${this.wares.length} 条）`)
              .fontSize(13)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
              .margin({ bottom: 8 })
          }
          ForEach(this.wares, (w: WareInfo) => {
            ListItem() {
              Row() {
                Column() {
                  Text(w.name)
                    .fontSize(14)
                    .fontColor(this.curWare === w.index ? AppTheme.ACCENT : AppTheme.TEXT_PRIMARY)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(w.url)
                    .fontSize(10)
                    .fontColor(AppTheme.TEXT_TERTIARY)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text(this.curWare === w.index ? '使用中' : '切换')
                  .fontSize(12)
                  .fontColor(this.curWare === w.index ? AppTheme.TEXT_TERTIARY : '#FFFFFF')
                  .backgroundColor(this.curWare === w.index ? AppTheme.CARD : AppTheme.ACCENT)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(AppTheme.RADIUS_PILL)
              }
              .width('100%')
              .padding({ top: 10, bottom: 10, left: 10, right: 10 })
              .backgroundColor(AppTheme.CARD)
              .borderRadius(10)
              .margin({ bottom: 8 })
              .onClick(() => {
                this.pickWare(w.index);
              })
            }
          }, (w: WareInfo) => `ware_${w.index}_${w.url}`)
        }

        /* 站点清单 */
        ListItem() {
          Row() {
            Text('站点清单')
              .fontSize(13)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .layoutWeight(1)
            Text(this.showSites ? '收起' : '展开')
              .fontSize(12)
              .fontColor(AppTheme.ACCENT)
              .onClick(() => {
                this.showSites = !this.showSites;
              })
          }
          .width('100%')
          .margin({ top: 8, bottom: 8 })
        }

        if (this.showSites) {
          ForEach(this.siteList(), (s: SiteModel) => {
            ListItem() {
              Row() {
                Column() {
                  Text(s.name)
                    .fontSize(13)
                    .fontColor(ConfigManager.get().isUsable(s) ? AppTheme.TEXT_PRIMARY : AppTheme.TEXT_TERTIARY)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(ConfigManager.get().isUsable(s) ? (s.api !== undefined ? s.api : '') : ConfigManager.get().unusableReason(s))
                    .fontSize(10)
                    .fontColor(AppTheme.TEXT_TERTIARY)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                if (ConfigManager.get().isUsable(s)) {
                  Text('禁用')
                    .fontSize(11)
                    .fontColor(AppTheme.TEXT_SECONDARY)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .backgroundColor(AppTheme.CARD)
                    .borderRadius(AppTheme.RADIUS_PILL)
                    .onClick(() => {
                      this.blockSite(s.key);
                    })
                }
              }
              .width('100%')
              .padding({ top: 9, bottom: 9, left: 10, right: 10 })
              .margin({ bottom: 6 })
              .backgroundColor(AppTheme.CARD)
              .borderRadius(8)
            }
          }, (s: SiteModel) => `site_${s.key}`)
        }

        ListItem() {
          Column() {
            Text('说明')
              .fontSize(12)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
              .margin({ bottom: 6 })
            Text('· 只支持 type:1 的 MacCMS(苹果CMS v10) 采集站，这类源的数据接口直接返回 JSON。\n'
              + '· type:3 的 Spider 站点依赖 Java JAR(DexClassLoader)，ArkTS 无法加载，已自动标记为不可用。\n'
              + '· 找不到片源时，换一个采集站更集中的配置源即可，无需改动 App。')
              .fontSize(11)
              .fontColor(AppTheme.TEXT_TERTIARY)
              .lineHeight(18)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 10, bottom: 30 })
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: PAD, right: PAD, top: 8 })
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

  /* ==================== 逻辑 ==================== */

  private refreshView(): void {
    const cfg = ConfigManager.get();
    this.wares = cfg.wares;
    this.curWare = cfg.currentWareIndex;
    // siteCount / allCount 已改为 @StorageProp 订阅，这里不再手动同步
    this.curUrl = cfg.rootUrl;
    this.builtinName = cfg.builtinName.length > 0 ? cfg.builtinName : '内置采集源';
    this.builtinSites = cfg.builtinSites;
    this.usingBuiltin = cfg.usingBuiltin;
  }

  /** 切回内置源（随包发布的配置，不依赖网络） */
  private async useBuiltin(): Promise<void> {
    if (this.busy || this.usingBuiltin) {
      return;
    }
    this.busy = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const ok: boolean = await ConfigManager.get().useBuiltin(ctx);
      this.busy = false;
      this.refreshView();
      AppStorage.setOrCreate('configVersion', this.bump());
      this.toast(ok ? `已启用内置源，可用站 ${ConfigManager.get().sites.length} 个` : '内置源加载失败');
    } catch (e) {
      this.busy = false;
      this.toast(`切换内置源异常：${e}`);
    }
  }

  private siteList(): SiteModel[] {
    return ConfigManager.get().allSites;
  }

  private async reloadCurrent(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const ok: boolean = await ConfigManager.get().reload(ctx);
      this.busy = false;
      this.refreshView();
      ConfigManager.get();
      AppStorage.setOrCreate('configVersion', this.bump());
      this.toast(ok ? '配置已更新' : `更新失败：${ConfigManager.get().lastError}`);
    } catch (e) {
      this.busy = false;
      this.toast(`更新异常：${e}`);
      Log.e(TAG, `reload failed: ${e}`);
    }
  }

  private async applyUrl(u: string): Promise<void> {
    const url: string = u.trim();
    if (url.length === 0) {
      this.toast('请输入配置地址');
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.toast('正在加载配置…');
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const ok: boolean = await ConfigManager.get().loadRoot(url, ctx, true);
      this.busy = false;
      this.inputUrl = '';
      this.refreshView();
      AppStorage.setOrCreate('configVersion', this.bump());
      this.toast(ok ? `加载成功，可用源 ${ConfigManager.get().sites.length} 个`
        : `加载失败：${ConfigManager.get().lastError}`);
    } catch (e) {
      this.busy = false;
      this.toast(`加载异常：${e}`);
    }
  }

  /** 从本地文件导入配置（电视端 / 无网络输入场景） */
  private async importLocal(): Promise<void> {
    if (this.busy) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const text: string = await PickerUtil.pickText(ctx, ['.json', '.txt']);
      if (text.length === 0) {
        this.toast('未选择文件');
        return;
      }
      this.busy = true;
      const ok: boolean = await ConfigManager.get().loadFromText(text, '本地配置', ctx);
      this.busy = false;
      this.refreshView();
      AppStorage.setOrCreate('configVersion', this.bump());
      this.toast(ok ? `导入成功，可用源 ${ConfigManager.get().sites.length} 个`
        : `导入失败：${ConfigManager.get().lastError}`);
    } catch (e) {
      this.busy = false;
      this.toast(`导入异常：${e}`);
    }
  }

  private async pickWare(index: number): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.toast('正在切换线路…');
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const ok: boolean = await ConfigManager.get().selectWare(index, ctx, true);
      this.busy = false;
      this.refreshView();
      AppStorage.setOrCreate('configVersion', this.bump());
      this.toast(ok ? `已切换到「${this.wares[index].name}」` : `切换失败：${ConfigManager.get().lastError}`);
    } catch (e) {
      this.busy = false;
      this.toast(`切换异常：${e}`);
    }
  }

  private async blockSite(key: string): Promise<void> {
    await ConfigManager.get().blockSite(key);
    this.refreshView();
    AppStorage.setOrCreate('configVersion', this.bump());
    this.toast('已禁用该站点');
  }

  private bump(): number {
    const v: number | undefined = AppStorage.get<number>('configVersion');
    return (v === undefined ? 0 : v) + 1;
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
    } catch (e) {
      Log.w(TAG, `toast failed: ${e}`);
    }
  }
}
