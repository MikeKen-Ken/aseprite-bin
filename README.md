<div align="center">

# 🎨 Aseprite 中文增强便携版

### 下载即中文 · 自动追踪更新 · 像素主题 · 无损更新

[![构建状态](https://github.com/MikeKen-Ken/aseprite-bin/actions/workflows/aseprite.yml/badge.svg)](https://github.com/MikeKen-Ken/aseprite-bin/actions/workflows/aseprite.yml) ![Windows x64](https://img.shields.io/badge/Windows-x64-0078D4?logo=windows11&logoColor=white) ![简体中文](https://img.shields.io/badge/Chinese-Built--in-E95420) ![便携版](https://img.shields.io/badge/Portable-No_Install-2EA44F)

基于 [mmozeiko/aseprite-bin](https://github.com/mmozeiko/aseprite-bin)<br>
为中文用户准备的 Aseprite Windows 自动构建

<br>

<a href="https://github.com/MikeKen-Ken/aseprite-bin/actions/workflows/aseprite.yml">
  <img src="https://img.shields.io/badge/Actions-%E7%AB%8B%E5%8D%B3%E6%9E%84%E5%BB%BA-2088FF?style=for-the-badge&logo=githubactions&logoColor=white" alt="立即构建">
</a>

</div>

## ✨ 这版多了什么

| 🇨🇳 **开箱即中文** | 🔄 **自动追踪更新** |
| --- | --- |
| 汉化已经内置并默认启用，无需手动安装。 | Aseprite 或汉化任意更新，都会触发新构建。 |
| 🎨 **更舒服的界面** | 🛡️ **更新不丢配置** |
| Boutique 亮/暗主题 + 像素字体，默认亮色。 | 一键更新旧文件夹，保留设置、快捷键和笔刷。 |

## ⚡ 和原版有什么不同

| | 上游原版 | 本中文增强版 |
| --- | :---: | :---: |
| 简体中文 | — | ✅ 内置并默认启用 |
| 版本追踪 | 手动运行 | ✅ Aseprite + 汉化自动追踪 |
| 主题与字体 | 默认资源 | ✅ Boutique + BoutiqueBitmap |
| 汉化兼容提示 | — | ✅ 精确匹配 / 旧版兜底 |
| 旧版本更新 | 手动覆盖 | ✅ 保留配置的一键更新 |
| 构建摘要 | 基础信息 | ✅ 中文摘要 |

## 🚀 三步开始

1. **Fork** 本仓库，并在自己仓库的 **Actions** 页面启用工作流。
2. 打开 **aseprite** 工作流，点击 **Run workflow**——两个输入框直接留空。
3. 构建完成后，在页面底部 **Artifacts** 下载压缩包。

> [!TIP]
> `version` 留空会自动选择 Aseprite 最新稳定版；汉化也会自动匹配。

<details>
<summary><b>📸 展开查看图文步骤</b></summary>

### Fork 仓库

![Fork 仓库](images/step1a.png)

![确认 Fork](images/step1b.png)

### 启用 Actions

![启用 Actions](images/step2.png)

### 运行工作流

![运行工作流](images/step3.png)

### 等待并下载

![等待构建完成](images/step4.png)

![下载构建产物](images/step5.png)

</details>

## 🔄 已有版本？直接无损更新

```text
把「旧 Aseprite 文件夹」
拖到「新版文件夹里的 update-existing.cmd」上
```

更新完成后：

- **新版程序会进入原来的旧文件夹**；
- `aseprite.ini`、快捷键、布局、笔刷等用户数据不会被覆盖；
- 下载并解压的新版临时文件夹会自动清理；
- 如果更新失败，临时文件会保留，方便重试。

> [!NOTE]
> 旧脚本中的 `FAILED 0 / Extras 4` 表示失败数为 0；`Extras` 是被保留的用户文件，
> 不是错误。新版脚本已经隐藏这段容易误解的信息。

## 🧩 汉化兼容状态

| ✅ `exact` | ⚠️ `fallback` | ❔ `compat-unverified` |
| --- | --- | --- |
| 与当前 Aseprite 精确匹配 | 使用适配旧版的汉化 | 使用最新汉化，但适配版本未知 |

找不到对应汉化时不会直接停止构建；产物名称、中文构建摘要和
`build-info.json` 都会明确显示兜底状态。

## 📦 默认体验

| 语言 | 主题 | 普通字体 | 小号字体 |
| --- | --- | --- | --- |
| 简体中文 `zh_Hans_ceta` | Boutique 亮色 | BoutiqueBitmap 9×9 | BoutiqueBitmap 7×7 |

> [!IMPORTANT]
> 亮色主题只用于全新便携版的首次默认设置。更新旧文件夹时会保留原来的
> `aseprite.ini`，不会强制改变你正在使用的主题。

<details>
<summary><b>⚙️ 展开查看高级说明</b></summary>

- 定时检查：约每三天一次，中国标准时间 09:17。
- `version`：留空自动选择 Aseprite 最新稳定版，也可填写指定版本。
- `chinese_release`：留空自动匹配，也可手动指定汉化 Release。
- `aseprite.defaults.ini`：仅记录本次构建默认值，不覆盖个人配置。
- `build-info.json`：记录 Aseprite、汉化、主题和兼容状态。
- 如需保留新版来源，可在更新前设置 `ASEPRITE_UPDATE_KEEP_SOURCE=1`。

</details>

## ❤️ 相关项目

[Aseprite](https://github.com/aseprite/aseprite) ·
[上游构建脚本](https://github.com/mmozeiko/aseprite-bin) ·
[简体中文扩展](https://github.com/Cetaceaqua/Aseprite-Simplified-Chinese-Extension) ·
[购买 Aseprite](https://www.aseprite.org/download/)

> [!WARNING]
> 本仓库只提供自动构建流程，不公开发布 Aseprite 二进制 Release。
> Actions 产物仅供构建者本人使用，请购买正版并遵守 Aseprite 许可条款。
