<p align="center">
  <img src="AppScope/resources/base/media/foreground.png" alt="影视观" width="120" height="120" />
</p>

<h1 align="center">影视观 · VideoHub</h1>

<p align="center">
  <strong>鸿蒙原生 · 第三方源影视聚合播放器</strong>
</p>

<p align="center">
  <a href="#-特性"><img src="https://img.shields.io/badge/HarmonyOS-NEXT-FF4D4F?logo=harmonyos&logoColor=white" alt="HarmonyOS NEXT"></a>
  <a href="#-特性"><img src="https://img.shields.io/badge/API-22%20%2F%206.0.2-blue" alt="API 22"></a>
  <a href="#-特性"><img src="https://img.shields.io/badge/Language-ArkTS-3178C6?logo=typescript&logoColor=white" alt="ArkTS"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green" alt="MIT"></a>
  <a href="#-特性"><img src="https://img.shields.io/badge/Version-2.8.8-8A2BE2" alt="Version 2.8.8"></a>
</p>

<p align="center">
  一款运行在 <b>HarmonyOS NEXT</b> 上的影视聚合客户端，动态解析 <b>TVBox 接口</b> 构建界面，
  用系统 <b>AVPlayer</b> 播放第三方源。轻量、快、纯原生，无广告、无冗余组件。
</p>

> ⚠️ **本项目为「空壳软件」**：仅提供播放器与解析框架，**不含任何内置影视资源**。所有内容均来自用户自行导入的第三方接口，详见 <a href="#-免责声明">免责声明</a>。

<p align="center">
  <a href="#-快速开始"><b>快速开始</b></a> ·
  <a href="#-核心特性"><b>核心特性</b></a> ·
  <a href="#-技术架构"><b>技术架构</b></a> ·
  <a href="#-项目结构"><b>项目结构</b></a> ·
  <a href="#-免责声明"><b>免责声明</b></a>
</p>

---

## ✨ 核心特性

- 🚀 **动态建 UI** — 无需写死站点，解析 TVBox 配置（单仓 / 多仓）后自动生成分类、筛选、页签
- 📺 **原生播放** — 基于系统 `AVPlayer` + `XComponent` 硬解，支持 m3u8 / mp4 等常见格式
- 🔄 **智能续播** — 精确记录进度（线路 + 集数对齐），一键接着上次的位置看
- ⚡ **多源切换** — 线路自由切换、按可用性排序、播放失败自动重连
- 🔍 **全局搜索** — 跨站聚合搜索，一次输入命中多个源
- 💾 **离线下载** — 下载到本地片库，无网也能看
- 📡 **投屏支持** — 内置投屏 / 音频路由能力，大屏观影无缝衔接
- 🎨 **双主题** — 白天亮堂 / 黑夜深色，一键切换
- 🧩 **沉浸体验** — 跟手翻页、骨架流光、海报淡入、流畅动效

---

## 🖼️ 界面预览

> 截图占位。将软件截图放入仓库后，替换下方 `screenshots/` 路径即可自动展示。

<div align="center">
  <table>
    <tr>
      <td align="center"><img src="screenshots/home.png" width="200" alt="首页"><br><sub>首页 · 跟手翻页分类</sub></td>
      <td align="center"><img src="screenshots/detail.png" width="200" alt="详情"><br><sub>详情 · 线路/选集</sub></td>
      <td align="center"><img src="screenshots/player.png" width="200" alt="播放"><br><sub>播放 · 手势控制</sub></td>
    </tr>
  </table>
</div>

<details>
<summary>📸 如何添加截图</summary>

1. 在仓库根目录新建 `screenshots/` 目录；
2. 将软件运行截图命名为 `home.png`、`detail.png`、`player.png` 等放入其中；
3. 提交后上表会自动展示。

> 也可自行增删 `<td>` 列以适配截图数量。
</details>

---

## 🚀 快速开始

### 环境要求

| 项 | 版本 |
|---|---|
| DevEco Studio | 5.x（支持 HarmonyOS NEXT） |
| HarmonyOS SDK | API 22 / 6.0.2 |
| 目标设备 | HarmonyOS NEXT（真机 / 模拟器） |

### 构建步骤

```bash
# 1. 用 DevEco Studio 打开项目，等待 sync 完成

# 2. 命令行构建（可选，需先配置 SDK 环境变量）
set DEVECO_SDK_HOME=D:\Program Files\Huawei\DevEco Studio\sdk
set OHOS_BASE_SDK_HOME=D:\Program Files\Huawei\DevEco Studio\sdk

hvigorw assembleHap --mode module -p product=default
```

构建产物位于：

```
entry/build/default/outputs/default/entry-default-unsigned.hap
```

### 安装到设备

1. 在 DevEco Studio 中打开 `File → Project Structure → Signing Configs`；
2. 勾选 **自动签名**（Sign In 华为账号）；
3. 点击 Run 部署到真机，或手动安装签名后的 HAP。

---

## 🧩 技术架构

```
┌─────────────────────────────────────────────────────┐
│                       UI 层 (ArkUI)                    │
│   首页 · 推荐 · 我的 · 搜索 · 详情 · 播放 · 下载 · 设置   │
└──────────────────────────┬──────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────┐
│                    数据 / 解析链                        │
│  ConfigManager → SiteProbe → SiteRouter →             │
│  PlayUrlParser → ParseResolver                        │
│  （三级兜底：网络 → 本地缓存 → 内置 rawfile）           │
└──────────────────────────┬──────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────┐
│                      播放内核                          │
│         AVPlayer + XComponent(Surface) 硬解            │
│         （投屏 · 音频路由 · 音频焦点 · 倍速）             │
└─────────────────────────────────────────────────────┘
```

**解析链说明**：`ConfigManager` 加载配置源 → `SiteProbe` 探活选出可用站 → `SiteRouter` 请求分类/详情 → `PlayUrlParser` 解析线路（`$$$` / `#`）→ `ParseResolver` 多类型解析（type0 直出，type1/2/3 POST/GET 回退），全部失败则进入嗅探。

---

## 📁 项目结构

```
yingshicang/
├── AppScope/                    # 应用级配置（bundleName、图标）
├── entry/                       # 主模块
│   └── src/main/ets/
│       ├── commons/             # 通用层（主题、组件、数据源、工具）
│       │   ├── component/       #   通用组件（海报、骨架、手势层…）
│       │   ├── datasource/      #   LazyForEach 数据源封装
│       │   ├── models/          #   数据模型
│       │   ├── theme/           #   双主题色板（AppTheme）
│       │   └── utils/           #   网络、存储、续播、投屏等工具
│       ├── entryability/        # UIAbility 入口
│       ├── features/            # 功能层（按业务拆分）
│       │   ├── home/            #   首页（分类、Swiper 翻页）
│       │   ├── recommend/       #   推荐（轮播、导轨）
│       │   ├── detail/          #   详情 + 播放器
│       │   ├── download/        #   本地片库
│       │   ├── search/          #   全局搜索
│       │   ├── source/          #   源管理
│       │   ├── setting/         #   设置
│       │   └── mine/            #   我的（历史、收藏）
│       └── products/default/    # 产品入口（Index 主界面）
└── tools/                       # 辅助脚本
```

---

## 🛠️ 技术栈

- **语言**：ArkTS（TypeScript 的超集，面向 HarmonyOS）
- **UI**：ArkUI 声明式框架
- **播放**：AVPlayer + XComponent（Surface 硬解渲染）
- **网络**：`@ohos.net.http`（每请求独立连接 + 异常兜底）
- **存储**：Preferences（设置 / 历史 / 收藏）
- **手势**：ArkUI 多层级手势体系（单击 / 双击 / 长按 / 横滑 / 竖滑）

---

## 📄 免责声明

> ⚠️ **本项目是一个「空壳软件」，不含任何内置影视内容与资源。**

本项目为**技术学习与交流**而开源，仅提供一个「解析第三方 TVBox 接口并播放」的**空壳框架**，**不内置、不提供、不传播任何影视资源、视频内容或侵权链接**。

- **空壳定位**：软件本身不包含任何影片、片源、图片等受版权保护的内容；所有内容均由用户**自行导入**的第三方接口提供，其版权与合法性完全由该接口提供方负责，与作者无关；
- **责任边界**：本项目不参与、不引导、不帮助获取或传播任何受版权保护或违法内容，作者对用户导入的第三方接口内容**不承担任何法律责任**；
- **合法使用**：请在遵守当地法律法规（包括但不限于著作权相关法律）的前提下使用，严禁用于任何商业用途或侵犯他人合法权益的行为；
- **后果自负**：用户使用本项目所产生的一切行为与后果（包括但不限于侵权、法律纠纷、数据损失等），均由用户自行承担，作者概不负责。

如发现本项目被用于任何违法违规用途，请立即停止使用并联系仓库维护者。

---

## 🤝 贡献

欢迎提交 Issue 与 PR。提交前请：

1. 遵循现有代码风格与目录约定；
2. 新增路由页时同步更新 `main_pages.json`；
3. 涉及播放逻辑时，注意同步检查 `VideoPlayerPage` / `VideoDetailPage` 两处。

---

## 📜 License

[MIT](LICENSE) © 影视观 · VideoHub
