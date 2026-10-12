import { media } from '@kit.MediaKit';

/**
 * 播放器的一条音轨 / 字幕轨。
 *
 * AVPlayer 的 `index` 不是数组下标，而是 getTrackDescription 返回的
 * `track_index`，selectTrack / deselectTrack 都要用它。
 */
export class TrackOption {
  /** MD_KEY_TRACK_INDEX */
  index: number = 0;
  /** 展示名（一般就是 codec_mime） */
  label: string = '';
  /** media.MediaType：0=音频 1=视频 2=字幕 */
  type: media.MediaType = media.MediaType.MEDIA_TYPE_AUD;
}
