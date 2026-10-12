import { media } from '@kit.MediaKit';
import { TrackOption } from '../../../commons/models/TrackModel';
import { AppTheme } from '../../../commons/theme/AppTheme';

/**
 * 一条轨道。
 *
 * 单独做成 @Component 而不是 @Builder：ForEach 回调里再嵌引用 this 的
 * 箭头函数会触发 es2abc 的 "An arrow function cannot have a 'this' parameter"。
 */
@Component
struct TrackRow {
  @Prop label: string = '';
  @Prop active: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Row() {
      Text(this.label)
        .fontSize(14)
        .fontColor(this.active ? '#FFFFFF' : AppTheme.TEXT_PRIMARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.active) {
        Text('使用中')
          .fontSize(11)
          .fontColor('#FFFFFF')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.active ? AppTheme.ACCENT : AppTheme.CARD)
    .borderRadius(10)
    .onClick(() => {
      this.onTap();
    })
  }
}

/**
 * 音轨 / 字幕切换面板。
 *
 * 轨道信息来自 AVPlayer.getTrackDescription()，只有 codec_mime 可用
 * （SDK 的 MediaDescriptionKey 没有语言字段），所以展示名直接用 mime。
 */
@CustomDialog
export struct PlayerTracksDialog {
  controller?: CustomDialogController;
  audioTracks: TrackOption[] = [];
  subtitleTracks: TrackOption[] = [];
  /** 当前选中的 track_index，-1 表示未指定 */
  currentAudio: number = -1;
  currentSubtitle: number = -1;

  /** type: media.MediaType.MEDIA_TYPE_AUD / MEDIA_TYPE_SUBTITLE；index = -1 表示关闭 */
  onPick: (type: number, index: number, label: string) => void = () => {
  };
  /**
   * 关闭回调：由父页传入 `() => this.tracksCtrl?.close()`。
   * ⚠️ 不靠框架注入的 `controller` —— 注入时序不保证，会让面板关不掉
   * （和 EpisodeDialog.onClose 同一个坑）。
   */
  onClose: () => void = () => {
  };

  build() {
    Column() {
      Text('音轨 / 字幕')
        .fontSize(16)
        .fontColor(AppTheme.TEXT_PRIMARY)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 10 })

      if (this.audioTracks.length === 0 && this.subtitleTracks.length === 0) {
        Text('当前片源没有可切换的音轨或字幕')
          .fontSize(12)
          .fontColor(AppTheme.TEXT_TERTIARY)
          .width('100%')
          .padding({ top: 20, bottom: 20 })
          .textAlign(TextAlign.Center)
      }

      List({ space: 8 }) {
        if (this.audioTracks.length > 0) {
          ListItem() {
            Text(`音轨（${this.audioTracks.length}）`)
              .fontSize(12)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
              .margin({ top: 4, bottom: 4 })
          }
          ForEach(this.audioTracks, (t: TrackOption) => {
            ListItem() {
              TrackRow({
                label: t.label,
                active: this.currentAudio === t.index,
                onTap: () => {
                  this.pick(t);
                }
              })
            }
          }, (t: TrackOption) => `aud_${t.index}`)
        }

        if (this.subtitleTracks.length > 0) {
          ListItem() {
            Text(`字幕（${this.subtitleTracks.length}）`)
              .fontSize(12)
              .fontColor(AppTheme.TEXT_SECONDARY)
              .width('100%')
              .margin({ top: 12, bottom: 4 })
          }
          ForEach(this.subtitleTracks, (t: TrackOption) => {
            ListItem() {
              TrackRow({
                label: t.label,
                active: this.currentSubtitle === t.index,
                onTap: () => {
                  this.pick(t);
                }
              })
            }
          }, (t: TrackOption) => `sub_${t.index}`)
          ListItem() {
            TrackRow({
              label: '关闭字幕',
              active: this.currentSubtitle < 0,
              onTap: () => {
                this.onPick(media.MediaType.MEDIA_TYPE_SUBTITLE, -1, '关闭字幕');
                this.close();
              }
            })
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('46%')
    .padding(16)
    .backgroundColor(AppTheme.SURFACE)
    .borderRadius({ topLeft: 18, topRight: 18 })
  }

  private pick(t: TrackOption): void {
    this.onPick(t.type, t.index, t.label);
    this.close();
  }

  private close(): void {
    this.onClose();
  }
}
