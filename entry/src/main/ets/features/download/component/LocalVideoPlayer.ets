import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppTheme } from '../../../commons/theme/AppTheme';
import { DownloadUtil } from '../../../commons/utils/DownloadUtil';
import { UrlUtil } from '../../../commons/utils/UrlUtil';
import { Log } from '../../../commons/utils/LogUtil';

const TAG = 'LocalPlayer';

/**
 * 本地已下载文件的播放器（「我的下载」里点开就用它）。
 *
 * 为什么不复用 `VideoPlayerPage`：
 *   那个页面的整套链路（siteKey → SiteRouter 取详情 → PlayUrlParser → ParseResolver）
 *   都是为**在线采集源**写的，拿一个沙箱里的本地文件进去没有任何一站能对上。
 *   本地文件只需要 `AVPlayer` + `file://` 直连，独立一个小组件最省事也最不容易出错。
 *
 * ⚠️ 起播时序和在线播放器**完全一致**（踩过的坑不重复踩）：
 *   ① `await setMediaSource(...)`；
 *   ② 状态机走到 `initialized` 才能设 `surfaceId`，设完**必须紧跟 `prepare()`**，
 *      否则永远停在 initialized（表现：一片黑 + 00:00 / 00:00）。
 *   `surfaceId` 在 `idle` 设会抛 5400102，所以不能写在 open() 里。
 *   而 XComponent 的 onLoad 和状态机是两条独立的异步线，**谁后到谁触发** prepare。
 */
@Component
export struct LocalVideoPlayer {
  /** 本地文件绝对路径（不带 file://） */
  path: string = '';
  /** 标题（片名 · 集名） */
  title: string = '';
  /** 关闭回调：由父页把这一层摘掉 */
  onClose: () => void = () => {
  };

  @State playing: boolean = false;
  @State posSec: number = 0;
  @State durSec: number = 0;
  @State status: string = '正在打开…';
  /** 拖动进度条期间压制 timeUpdate 回写，否则滑块会被往回拽 */
  @State dragging: boolean = false;

  private player: media.AVPlayer | undefined = undefined;
  /** fd:// 兜底时打开的文件句柄，播放期间必须一直持有 */
  private fileHandle: fs.File | undefined = undefined;
  private xc: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private surfaceReady: boolean = false;
  private released: boolean = false;
  /** 画面区域实测尺寸，用来把画面等比摆正（surface 会拉伸填满） */
  @State areaW: number = 0;
  @State areaH: number = 0;
  private vw: number = 0;
  private vh: number = 0;

  aboutToAppear(): void {
    this.open();
  }

  aboutToDisappear(): void {
    this.release();
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      /* 画面：按真实宽高比摆放，多出来的地方由黑底补成黑边 */
      XComponent({
        id: 'local_video',
        type: XComponentType.SURFACE,
        controller: this.xc
      })
        .onLoad(() => {
          this.surfaceId = this.xc.getXComponentSurfaceId();
          this.surfaceReady = true;
          Log.i(TAG, `surfaceId=${this.surfaceId}`);
          this.maybePrepare();
        })
        .onDestroy(() => {
          this.surfaceId = '';
          this.surfaceReady = false;
        })
        .width(this.renderW())
        .height(this.renderH())
        .backgroundColor('#000000')

      /* 顶部：关闭 + 标题 */
      Row({ space: 10 }) {
        Row() {
          Text('✕')
            .fontSize(17)
            .fontColor('#FFFFFF')
            .width(34)
            .height(34)
            .textAlign(TextAlign.Center)
            .backgroundColor('rgba(255,255,255,0.14)')
            .borderRadius(17)
            .onClick(() => {
              this.onClose();
            })
        }
        .width(34)
        .height(34)
        .justifyContent(FlexAlign.Center)

        Text(this.title.length > 0 ? this.title : '本地视频')
          .fontSize(15)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8 })
      .align(Alignment.TopStart)
      .hitTestBehavior(HitTestMode.None)

      /* 底部：播放 / 进度 / 时长 */
      Column({ space: 4 }) {
        Row() {
          Text(UrlUtil.formatTime(this.posSec))
            .fontSize(11)
            .fontColor('#FFFFFF')
            .width(46)
            .textAlign(TextAlign.Start)
            .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
          Slider({
            value: this.posSec,
            min: 0,
            max: this.durSec > 0 ? this.durSec : 1,
            step: 1,
            style: SliderStyle.OutSet
          })
            .selectedColor(AppTheme.ACCENT)
            .trackColor('rgba(255,255,255,0.28)')
            .blockColor('#FFFFFF')
            .blockSize({ width: 13, height: 13 })
            .trackThickness(4)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.Moving) {
                this.dragging = true;
                this.posSec = Math.floor(value);
              } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.dragging = false;
                this.seekTo(value);
              }
            })
          Text(UrlUtil.formatTime(this.durSec))
            .fontSize(11)
            .fontColor('#FFFFFF')
            .width(46)
            .textAlign(TextAlign.End)
            .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
        }
        .width('100%')

        Row({ space: 14 }) {
          Row() {
            Image(this.playing ? $r('app.media.player_ic_pause') : $r('app.media.player_ic_play'))
              .width(22)
              .height(22)
              .objectFit(ImageFit.Contain)
              .draggable(false)
              .interpolation(ImageInterpolation.High)
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('rgba(255,255,255,0.14)')
          .borderRadius(20)
          .onClick(() => {
            this.togglePlay();
          })

          if (this.status.length > 0) {
            Text(this.status)
              .fontSize(11)
              .fontColor('#E3E7EF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
          } else {
            Row().layoutWeight(1).hitTestBehavior(HitTestMode.None)
          }
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 16 })
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [
          ['rgba(0,0,0,0.0)', 0.0],
          ['rgba(0,0,0,0.72)', 1.0]
        ]
      })
      .align(Alignment.BottomStart)
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const w: number = newArea.width as number;
      const h: number = newArea.height as number;
      if (Math.abs(w - this.areaW) > 0.5 || Math.abs(h - this.areaH) > 0.5) {
        this.areaW = w;
        this.areaH = h;
      }
    })
  }

  /* ==================== 播放器 ==================== */

  private async open(): Promise<void> {
    try {
      const p: media.AVPlayer = await media.createAVPlayer();
      if (this.released) {
        p.release();
        return;
      }
      this.player = p;
      p.on('stateChange', (state: media.AVPlayerState) => {
        this.onState(p, state);
      });
      p.on('timeUpdate', (time: number) => {
        if (!this.dragging) {
          this.posSec = Math.floor(time / 1000);
        }
      });
      p.on('durationUpdate', (duration: number) => {
        this.durSec = Math.floor(duration / 1000);
      });
      p.on('videoSizeChange', (width: number, height: number) => {
        if (width > 0 && height > 0) {
          this.vw = width;
          this.vh = height;
        }
      });
      p.on('error', (err: BusinessError) => {
        this.playing = false;
        this.status = `播放出错 ${err.code}`;
        Log.e(TAG, `error ${err.code} ${err.message}`);
      });
      const src: media.MediaSource = media.createMediaSourceWithUrl(DownloadUtil.fileUrl(this.path));
      try {
        await p.setMediaSource(src);
      } catch (e) {
        /*
         * 兜底：个别 ROM 对沙箱文件的 `file://` 形式支持不完整。
         * 换成 `fd://<文件描述符>` —— 这是本地文件最"官方"的喂法，只要文件能打开就能播。
         * 注意 fd 必须在播放期间保持打开，所以 File 对象要一直持有（release 时才关）。
         */
        Log.w(TAG, `file:// rejected (${e}), retry with fd://`);
        const f: fs.File = await fs.open(this.path, fs.OpenMode.READ_ONLY);
        this.fileHandle = f;
        const fdSrc: media.MediaSource = media.createMediaSourceWithUrl(`fd://${f.fd}`);
        await p.setMediaSource(fdSrc);
      }
      Log.i(TAG, `setMediaSource ok state=${p.state}`);
      // 状态机可能已经走到 initialized（比 onLoad 早），这里补一次
      this.maybePrepare();
    } catch (e) {
      const err = e as BusinessError;
      this.status = `无法打开：${err.code}`;
      Log.e(TAG, `open failed ${err.code} ${err.message}`);
    }
  }

  /**
   * 起播闸门：表面就绪 + 播放器已到 initialized，谁后到谁触发。
   * 缺任何一个都起不来（surfaceId 只能在 initialized 设）。
   */
  private maybePrepare(): void {
    const p: media.AVPlayer | undefined = this.player;
    if (p === undefined || this.released) {
      return;
    }
    if (!this.surfaceReady || this.surfaceId.length === 0) {
      return;
    }
    if (p.state !== 'initialized') {
      return;
    }
    try {
      p.surfaceId = this.surfaceId;
      p.prepare().then(() => {
        Log.i(TAG, 'prepared');
      }).catch((e: BusinessError) => {
        this.status = `准备失败 ${e.code}`;
        Log.e(TAG, `prepare failed ${e.code}`);
      });
    } catch (e) {
      Log.e(TAG, `maybePrepare threw: ${e}`);
    }
  }

  private onState(p: media.AVPlayer, state: media.AVPlayerState): void {
    if (state === 'initialized') {
      this.maybePrepare();
      return;
    }
    if (state === 'prepared') {
      this.status = '';
      this.safe(() => p.play(), 'auto play');
      return;
    }
    if (state === 'playing') {
      this.playing = true;
      this.status = '';
      return;
    }
    if (state === 'paused') {
      this.playing = false;
      return;
    }
    if (state === 'completed') {
      this.playing = false;
      this.posSec = this.durSec;
      return;
    }
    if (state === 'error') {
      this.playing = false;
    }
  }

  private togglePlay(): void {
    const p: media.AVPlayer | undefined = this.player;
    if (p === undefined) {
      return;
    }
    if (p.state === 'playing') {
      this.safe(() => p.pause(), 'pause');
    } else if (p.state === 'paused' || p.state === 'prepared' || p.state === 'completed') {
      this.safe(() => p.play(), 'play');
    }
  }

  private seekTo(sec: number): void {
    const p: media.AVPlayer | undefined = this.player;
    if (p === undefined) {
      return;
    }
    try {
      p.seek(Math.floor(sec) * 1000);
    } catch (e) {
      Log.w(TAG, `seek failed: ${e}`);
    }
  }

  private release(): void {
    this.released = true;
    const p: media.AVPlayer | undefined = this.player;
    this.player = undefined;
    const f: fs.File | undefined = this.fileHandle;
    this.fileHandle = undefined;
    if (p !== undefined) {
      p.release().then(() => {
        Log.i(TAG, 'released');
      }).catch((e: BusinessError) => {
        Log.w(TAG, `release failed ${e.code}`);
      });
    }
    if (f !== undefined) {
      // 播放器都放掉了才能关 fd
      fs.close(f).catch((e: BusinessError) => {
        Log.w(TAG, `close fd failed ${e.code}`);
      });
    }
  }

  /** `pause()/play()/prepare()` 都是**同步抛**的接口，必须用闭包包住 */
  private safe(run: () => Promise<void>, what: string): void {
    try {
      run().then(() => {
      }).catch((e: BusinessError) => {
        Log.w(TAG, `${what} failed ${e.code}`);
      });
    } catch (e) {
      Log.w(TAG, `${what} threw: ${e}`);
    }
  }

  /* ==================== 画面尺寸 ==================== */

  private ratio(): number {
    if (this.vw > 0 && this.vh > 0) {
      return this.vw / this.vh;
    }
    return 16 / 9;
  }

  private renderW(): number {
    const r: number = this.ratio();
    if (this.areaW <= 0 || this.areaH <= 0) {
      return this.areaW;
    }
    const h: number = this.areaW / r;
    return h <= this.areaH ? this.areaW : this.areaH * r;
  }

  private renderH(): number {
    const r: number = this.ratio();
    if (this.areaW <= 0 || this.areaH <= 0) {
      return this.areaH;
    }
    const h: number = this.areaW / r;
    return h <= this.areaH ? h : this.areaH;
  }
}
