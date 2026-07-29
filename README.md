# Aseprite 中文增强便携版｜Windows 自动构建

[![Aseprite 构建状态](https://github.com/MikeKen-Ken/aseprite-bin/actions/workflows/aseprite.yml/badge.svg)](https://github.com/MikeKen-Ken/aseprite-bin/actions/workflows/aseprite.yml)

这是 [`mmozeiko/aseprite-bin`](https://github.com/mmozeiko/aseprite-bin) 的
**中文增强分支**。它保留了原版使用 GitHub Actions 编译 64 位 Windows
[Aseprite](https://github.com/aseprite/aseprite) 的能力，并重点解决了中文用户
下载后还要安装汉化、配置主题、手动追踪版本，以及更新时容易覆盖个人配置的问题。

## 与原版的区别

> 这里的“原版”指上游
> [`mmozeiko/aseprite-bin`](https://github.com/mmozeiko/aseprite-bin)，
> 不是 Aseprite 官方发行版。

| 功能 | 上游原版 | 本中文增强版 |
| --- | --- | --- |
| Windows 64 位自动编译 | ✅ | ✅ |
| 手动留空版本号时构建最新稳定版 | ✅ | ✅ |
| 定时追踪 Aseprite 新版本 | ❌ | ✅ 约每三天自动检查 |
| 内置简体中文并默认启用 | ❌ | ✅ 鲸流的简体中文 |
| 自动追踪汉化插件更新 | ❌ | ✅ 汉化单独更新也会重新构建 |
| 汉化兼容性映射 | ❌ | ✅ 优先精确匹配，并提供最新版本兜底 |
| 旧汉化提示 | ❌ | ✅ 在产物名、插件名、摘要和构建信息中明确标记 |
| Boutique 亮色与深色主题 | ❌ | ✅ 两者均内置，首次默认使用亮色 |
| BoutiqueBitmap 像素字体 | ❌ | ✅ 9×9 普通字体与 7×7 小号字体 |
| 中文 Actions 构建摘要 | ❌ | ✅ 版本、兼容状态、主题和产物信息均为中文 |
| 保留配置的一键更新 | ❌ | ✅ `update-existing.cmd` |
| 更新后自动清理下载副本 | ❌ | ✅ 成功后清理，失败时保留以便重试 |
| 便携版构建信息 | ❌ | ✅ 内置 `build-info.json` |

### 这个版本最重要的改进

- **下载即可中文使用**：语言、主题和字体已经放入便携版，无需再次安装扩展。
- **Aseprite 和汉化都能自动追踪**：任意一方发布新版本，定时 Action 都会尝试重新构建。
- **不会悄悄混用旧汉化**：找不到精确对应版本时仍可构建，但会明确显示
  `fallback` 或 `compat-unverified`。
- **更新不再覆盖个人设置**：把旧文件夹拖到新版的 `update-existing.cmd` 上，
  程序会在旧文件夹中完成更新，同时保留配置、快捷键、布局、笔刷和其他用户数据。
- **新版来源自动清理**：更新成功后删除本次解压的临时副本，不再长期保留多个版本目录。

> [!IMPORTANT]
> 本仓库提供的是自动化构建流程，不公开发布 Aseprite 二进制 Release。
> Actions 产物仅供构建者本人使用。请购买
> [Aseprite 正版授权](https://www.aseprite.org/download/)，并遵守其许可条款。

## 本版本的默认产物

| 项目 | 默认设置 |
| --- | --- |
| Aseprite | 最新稳定版，或手动指定的版本 |
| 简体中文 | 自动匹配 [鲸流的简体中文扩展](https://github.com/Cetaceaqua/Aseprite-Simplified-Chinese-Extension/releases) |
| 主题 | 内置 Boutique 亮色与深色主题，首次启动默认使用亮色 `boutique` |
| 正常界面字体 | `BoutiqueBitmap9x9` |
| 小号界面字体 | `BoutiqueBitmap7x7` |
| 便携模式 | 配置和用户数据保存在 Aseprite 文件夹内 |
| 安全更新 | 附带 `update-existing.cmd`，更新程序时保留旧配置 |

全新解压的构建默认使用：

- 语言：`zh_Hans_ceta`
- 主题：Boutique 亮色 `boutique`
- 普通字体：BoutiqueBitmap 9×9
- 小号字体：BoutiqueBitmap 7×7

这些只是首次启动默认值，之后仍可在 Aseprite 的“首选项”中自由修改。

## 快速开始

### 1. Fork 本仓库

点击页面右上角的 **Fork**，把仓库复制到自己的 GitHub 账号。

![Fork 仓库](images/step1a.png)

![确认 Fork](images/step1b.png)

### 2. 启用 GitHub Actions

进入自己仓库的 **Actions** 页面并启用工作流。

![启用 Actions](images/step2.png)

### 3. 运行构建

打开名为 **aseprite** 的工作流，点击 **Run workflow**。

![运行工作流](images/step3.png)

两个输入框都可以留空：

| 输入项 | 留空时 | 填写示例 |
| --- | --- | --- |
| `version` | 自动获取 Aseprite 最新稳定版 | `v1.3.18.1` |
| `chinese_release` | 自动匹配汉化，找不到对应版本时使用最新稳定汉化 | `0.1.15` |

通常直接留空运行即可，不再需要每次手动输入 Aseprite 版本号。

### 4. 下载构建产物

等待构建完成，打开本次运行记录。

![等待构建完成](images/step4.png)

在页面底部的 **Artifacts** 区域下载压缩包。

![下载构建产物](images/step5.png)

GitHub Actions 的 Build Summary 会用中文显示 Aseprite 版本、汉化版本、
兼容状态、默认主题、字体和最终产物名称。

## 自动检查与定时构建

工作流大约每三天自动检查一次，执行时间为：

- UTC：01:17
- 中国标准时间（UTC+8）：09:17

每次检查都会同时解析：

1. Aseprite 最新稳定版；
2. 当前应使用的简体中文扩展 Release；
3. 汉化与 Aseprite 的兼容状态。

只要 Aseprite 或汉化插件任意一方发生变化，就会重新构建。两者都没有变化时，
定时任务会跳过耗时的编译。Beta、RC、预发布和草稿 Release 不会被当作最新稳定版。

上一次成功构建的组合状态记录在 `.github/last-built-version.txt`。只有完整构建和
产物上传成功后才会更新该记录，因此失败的构建不会阻止下一次自动重试。

## 汉化版本匹配与兜底

构建脚本会优先寻找与目标 Aseprite 精确对应的最新汉化：

1. 读取 `config/chinese-extension-compatibility.json` 中的兼容性映射；
2. 检查汉化 Release 的名称、说明和对应提交；
3. 优先选择明确支持当前 Aseprite 的最新 Release；
4. 无法确认对应关系时，继续使用汉化仓库的最新稳定 Release。

构建不会因为缺少精确对应版本而直接停止，但会明确标记兼容状态：

| 标记 | 含义 |
| --- | --- |
| `exact` | 汉化与目标 Aseprite 精确匹配 |
| `fallback` | 使用了原本适配旧版 Aseprite 的汉化 |
| `compat-unverified` | 已使用最新稳定汉化，但无法确认其适配版本 |

兜底状态会出现在：

- GitHub Actions 中文构建摘要；
- Actions 产物名称；
- Aseprite 中的语言扩展显示名称；
- 产物内的 `build-info.json`。

例如：

```text
aseprite-v1.3.19-zh-0.1.15-boutique-fallback-from-1.3.18.1
```

表示 Aseprite `v1.3.19` 使用了原本识别为适配 `v1.3.18.1` 的汉化 `0.1.15`。

## 无损更新已有的便携版

不要直接把新版文件全部覆盖到旧 Aseprite 文件夹。旧文件夹中的
`aseprite.ini` 保存了语言、主题、窗口布局和其他首选项。

推荐操作：

1. 把新下载的 Actions 产物解压到临时位置；
2. 找到新版目录内的 `update-existing.cmd`；
3. 把正在使用的旧 Aseprite 文件夹拖到 `update-existing.cmd` 上；
4. 等待脚本提示更新完成；
5. 以后继续运行旧文件夹里的 `aseprite.exe`。

更新关系可以理解为：

```text
新下载并解压的文件夹  --复制新版程序/汉化/主题-->  原来的旧 Aseprite 文件夹
                                                    ↑
                                      最终继续使用这个文件夹
```

更新脚本会：

- 更新 `aseprite.exe`、程序数据、汉化和 Boutique 主题；
- 保留旧的 `aseprite.ini`；
- 保留快捷键、布局、笔刷、会话、调色板和其他用户文件；
- 不删除旧目录中新版不存在的额外文件；
- 更新成功后自动删除本次解压出来的新版来源文件夹；
- 如果外层 Actions 产物目录已经为空且名称匹配，也会一并清理；
- 更新失败时保留新版来源，方便排查后重新执行。

因此，更新完成后的新版位于**原来的旧文件夹**中，新下载的临时副本会被清理。

如果希望在更新成功后仍保留新版来源，可在运行前设置：

```bat
set ASEPRITE_UPDATE_KEEP_SOURCE=1
```

### 为什么旧脚本显示 `Extras 4`

旧版更新脚本可能显示类似：

```text
FAILED 0
Extras 4
```

这表示失败数量为 `0`。`Extras` 是旧目录中存在、但新版来源中没有的用户目录或文件，
例如 `files`、`sessions`、快捷键和布局。脚本会保留它们，并不是更新失败。
新版脚本已经隐藏这段容易误解的 Robocopy 统计信息。

## 默认配置与现有配置的区别

- `aseprite.ini`：当前实际使用的个人配置，更新时始终保留。
- `aseprite.defaults.ini`：本次构建附带的默认值，仅供查看，不会覆盖个人配置。
- `build-info.json`：记录 Aseprite 版本、汉化 Release、兼容状态、主题、字体和产物名称。

Boutique 亮色主题只作为**全新构建的首次默认主题**。通过 `update-existing.cmd`
更新已有目录时，因为旧的 `aseprite.ini` 会被保留，所以不会强制改变你当前使用的
语言、主题或其他首选项。

## 常见问题

### 每次运行 Action 都要填写版本号吗？

不需要。`version` 留空时会自动构建 Aseprite 最新稳定版。

### Aseprite 没更新，但汉化插件更新了，会重新构建吗？

会。定时任务比较的是 Aseprite、汉化 Release 和兼容状态的组合。

### 找不到与新版 Aseprite 对应的汉化怎么办？

构建会使用最新稳定汉化继续完成，并通过 `fallback` 或 `compat-unverified`
清楚标记，不会悄悄把旧汉化伪装成精确匹配。

### 更新完成后应该打开哪个文件夹？

继续使用原来的旧 Aseprite 文件夹，并运行其中的 `aseprite.exe`。

### 更新会覆盖我的主题和快捷键吗？

不会。更新脚本保留 `aseprite.ini` 和其他用户文件。只有全新解压、首次使用的构建
才会默认选择 Boutique 亮色主题。

## 相关项目

- [Aseprite 源代码](https://github.com/aseprite/aseprite)
- [Aseprite 版本列表](https://github.com/aseprite/aseprite/tags)
- [Aseprite 官方购买与下载](https://www.aseprite.org/download/)
- [Aseprite 简体中文扩展](https://github.com/Cetaceaqua/Aseprite-Simplified-Chinese-Extension)
