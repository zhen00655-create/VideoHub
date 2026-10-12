/**
 * 全局常量
 */

/** 桌面 Chrome UA —— 多数 MacCMS 采集站对空 UA / 默认 UA 会返回 403 或空数据 */
export const DEFAULT_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

/** 移动端 UA，部分源按 UA 返回不同清晰度时可用 */
export const MOBILE_UA: string =
  'Mozilla/5.0 (Linux; Android 14; PHK110) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';

/** 内置 rawfile 兜底配置 */
export const BUILTIN_CONFIG_FILE: string = 'default_config.json';

/**
 * 预置配置源地址（源管理页展示，用户可自行增删）。
 * 顺序按实测连通性排：jsDelivr 可用，raw.githubusercontent 在境内基本不可达放最后。
 */
export const PRESET_CONFIG_URLS: string[] = [
  'https://cdn.jsdelivr.net/gh/qist/tvbox@master/xiaosa/api.json',
  'https://cdn.jsdelivr.net/gh/gaotianliuyun/gao@master/0821.json',
  'https://raw.githubusercontent.com/qist/tvbox/master/xiaosa/api.json'
];

/** preferences 库名 */
export const SP_NAME: string = 'video_hub_store';

/** preferences key */
export const KEY_CONFIG_URL: string = 'current_config_url';
export const KEY_CONFIG_LIST: string = 'config_url_list';
export const KEY_SITE_BLACKLIST: string = 'site_blacklist';
export const KEY_HISTORY: string = 'play_history';
/** 上次探测可用的资源站 key */
export const KEY_SITE_KEY: string = 'current_site_key';
export const KEY_FAVORITE: string = 'favorite_list';

/** 站点类型 */
export const SITE_TYPE_XML: number = 0;
export const SITE_TYPE_JSON: number = 1;
export const SITE_TYPE_SPIDER: number = 3;

/** 解析器类型 */
export const PARSE_TYPE_DIRECT: number = 0;
export const PARSE_TYPE_JSON: number = 1;
export const PARSE_TYPE_JSON_EXT: number = 2;
export const PARSE_TYPE_AGG: number = 3;

/** 可直接交给播放器的媒体后缀（小写，含点） */
export const MEDIA_EXTENSIONS: string[] = [
  '.m3u8', '.mp4', '.flv', '.mkv', '.avi', '.mov', '.ts', '.m4v', '.webm', '.mp3', '.m4a', '.rmvb', '.wmv'
];

/** 网络超时 */
export const TIMEOUT_CONFIG: number = 15000;
export const TIMEOUT_API: number = 12000;
export const TIMEOUT_PARSE: number = 20000;

/** 首页每页条数 */
export const PAGE_SIZE: number = 20;
