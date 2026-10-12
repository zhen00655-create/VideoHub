"""
采集站探活工具（PC 侧运行，用于筛选内置源里的 api 地址）。

用法:
    python tools/probe_sources.py                 # 探测脚本内置的候选列表
    python tools/probe_sources.py url1 url2 ...   # 探测指定 api 地址

判定标准（与 App 内的取数逻辑保持一致）:
    1. `?ac=list` 能返回 JSON，且 `class` 非空        -> 分类可用
    2. `?ac=videolist&t=<id>&pg=1` 的叶子分类有数据   -> 内容可用
    3. `?ac=videolist&h=24&pg=1` 有数据               -> 「最近更新」可用

注意：MacCMS 的父分类（type_pid=0）在多数站点用 `t=<父id>` 查不到数据，
App 首页因此固定用「最近更新」+ 二级分类下钻，不依赖父分类。
"""

import concurrent.futures as cf
import json
import ssl
import sys
import urllib.request

UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CANDIDATES = [
    'https://360zy.com/api.php/provide/vod/',
    'https://api.ffzyapi.com/api.php/provide/vod/',
    'https://cj.ffzyapi.com/api.php/provide/vod/',
    'https://api.guangsuapi.com/api.php/provide/vod/',
    'https://cj.lziapi.com/api.php/provide/vod/',
    'https://api.wujinapi.me/api.php/provide/vod/',
    'https://api.zuidapi.com/api.php/provide/vod/',
    'https://caiji.dyttzyapi.com/api.php/provide/vod/',
    'https://api.douapi.cc/api.php/provide/vod/',
    'https://json.heimuer.xyz/api.php/provide/vod/',
    'https://collect.wolongzyw.com/api.php/provide/vod/',
]


def get(url):
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept': '*/*'})
    with urllib.request.urlopen(req, timeout=15, context=CTX) as r:
        return json.loads(r.read().decode('utf-8', 'ignore'))


def probe(api):
    try:
        classes = get(api + '?ac=list').get('class') or []
    except Exception as e:
        return api, 'DEAD', f'class-fail {str(e)[:36]}'
    if not classes:
        return api, 'DEAD', 'no class'

    parents = [c for c in classes if int(c.get('type_pid') or 0) == 0]
    leaves = [c for c in classes if int(c.get('type_pid') or 0) != 0]
    target = (leaves or parents)[0]
    try:
        n = len(get(api + f"?ac=videolist&t={target['type_id']}&pg=1").get('list') or [])
    except Exception as e:
        return api, 'DEAD', f'list-fail {str(e)[:36]}'
    try:
        latest = len(get(api + '?ac=videolist&h=24&pg=1').get('list') or [])
    except Exception:
        latest = 0

    st = 'PASS' if n > 0 else 'WEAK'
    return api, st, (f"class={len(classes)} parent={len(parents)} leaf={len(leaves)} "
                     f"t={target['type_id']}->{n} latest24h={latest}")


def main():
    apis = sys.argv[1:] or CANDIDATES
    with cf.ThreadPoolExecutor(12) as ex:
        for api, st, info in ex.map(probe, apis):
            print(f'{st:5s} {api:52s} {info}')


if __name__ == '__main__':
    main()
