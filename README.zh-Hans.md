<div align="center">
    <img src="images/Voanisa-icon-512-rounded.png" alt="Logo" width="206" />
    <h1>Voanisa</h1>
</div>

# Voanisa

为 macOS 打造的本地音乐库，视觉风格向 Elysia 靠拢。

[English](./README.md) · **简体中文**

## 官网

[voanisa.macwave.org](https://voanisa.macwave.org)（短链接：[v.macwave.org](https://v.macwave.org)）

## 下载

[点击前往下载页面](https://voanisa.macwave.org/Downloads/)

本仓库包含 **Voanisa 1.0.2**。每个导入的音频文件都会成为曲库中的一首歌曲。
音频会被复制进自包含的曲库，由用户命名、配上正方形封面，并在本机播放——
不依赖 Apple Music，也不会在曲库之外写入任何文件。

## 编程语言

应用与可移植核心由 Swift、Rust 编写。C 只出现在两者之间的两个 FFI 头文件里，SQL 通过核心里的 SQLite 使用；头文件、Shell/Python 工具与配置文件都不计入 GitHub 的语言统计，让语言条只反映项目真正使用的两种语言。

## 环境要求

- macOS 15（Sequoia）或更高版本
- 构建需要 Xcode 16.4 或更高版本

## 原型功能

- 从侧边栏、拖放或 ⌘O 导入音频文件或整个文件夹
- 根据**文件头**判断容器格式，不依赖扩展名
- 文件带有标签时，自动填充歌名、歌手、专辑、专辑艺术家、曲目/碟号与封面
- 为每首歌曲填写歌名、歌手、专辑、专辑艺术家、曲目/碟号，并拖动缩放裁剪正方形封面
- 随时从行菜单编辑元数据、替换或移除封面
- 创建歌单、加入/移除歌曲、重命名与删除歌单
- 根据专辑与专辑艺术家标签自动聚合专辑
- 上一首/下一首严格跟随当前看到的列表——曲库、歌单或专辑，不会跳到无关队列
- 没有封面的歌曲在各处统一显示灰色音符占位图
- 音频复制到 `~/Music/Voanisa`，原文件保持不变
- 本地播放：播放/暂停、上一首/下一首、进度、音量、循环、媒体键
- 搜索、拖动排序、悬停播放按钮、双击播放
- Elysia 风格的简洁列表：左侧封面，歌名在上、歌手在下，正在播放时显示红色
- 英文与简体中文界面

### 支持的格式

MP3、AAC/ADTS、M4A、ALAC、FLAC、WAV、AIFF、CAF。

以下格式由 Rust 核心在进程内解码，再交给 `AVAudioEngine` 播放。不依赖任何外部
解码器程序、编解码包或 ffmpeg 安装。

- Ogg Vorbis —— Symphonia
- Ogg Opus —— `opus-pure`（Ogg 封装、pre-skip 与 end-trim 修正）
- WavPack —— `wavicle`（无损，单/双声道最高 32 位；不支持混合模式与 DSD；
  超过约 19 分钟的双声道 44.1 kHz 文件会超出内存解码上限）
- Monkey's Audio（APE）—— `ape-decoder`（支持全部压缩等级与按帧定位；
  适用于 Monkey's Audio 3.95 及以上版本写出的文件）

MP4/MOV 会作为纯音频 M4A 导入，视频轨道会被丢弃。

WMA、DSD（DSF/DFF）、Matroska/WebM 可以被文件头识别，但暂不支持解码。WMA 在
macOS 上完全无法解码，请先转成 FLAC 或 MP3 —— 仓库里的 `Scripts/convert-wma.sh`
可以用 ffmpeg 一次转完整个文件夹。

## 曲库

```
~/Music/Voanisa/
  library.sqlite         # 主存储
  library.json           # 可移植快照与备份
  Media/                 # 音频文件，UUID 命名
  Covers/Originals/      # 用户上传的封面原图
  Covers/Rendered/       # 界面使用的正方形封面
  .staging/              # 导入临时区
```

歌曲保存在 `library.sqlite` 中。每次修改后 Voanisa 还会写入
`library.json`；已有的快照会在启动时迁移进 SQLite，并在数据库不可用时用于
恢复。导入时选择的原文件不会被修改或移动。

## 构建

Xcode 工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 根据
`project.yml` 生成：

```sh
xcodegen generate
open Voanisa.xcodeproj
```

生成 `dmg/` 下的通用架构 DMG：

```sh
Scripts/package-dmg.sh
```

脚本会使用钥匙串中第一个 `Apple Development` 证书；可通过 `SIGN_IDENTITY`
覆盖，或设为 `-` 使用 ad-hoc 签名。Hardened Runtime 被刻意关闭：应用采用直接
分发，个人开发者团队也无法公证。

### 查看打包好的镜像

`Scripts/voanisadmgrun` 会挂载镜像并在 Finder 中打开，是检查安装体验最快的
方式：

```sh
Scripts/voanisadmgrun              # dmg/ 下最新的镜像
Scripts/voanisadmgrun path.dmg     # 指定镜像
Scripts/voanisadmgrun --eject      # 卸载
```

想把它当作普通命令使用，可以链接到 `PATH` 中的目录：

```sh
ln -s "$PWD/Scripts/voanisadmgrun" ~/.local/bin/voanisadmgrun
```

构建已签名但未公证，首次打开时 Gatekeeper 可能要求右键 → 打开。也可以清除
隔离标记：

```sh
xattr -dr com.apple.quarantine /Applications/Voanisa.app
```

## 应用图标

仓库中的图标是临时版本。替换
`images/Voanisa-icon-1024.png` 后重新生成全套尺寸：

```sh
python3 Scripts/generate-appicon.py images/Voanisa-icon-1024.png
```

## 路线图

1. Rust 可移植核心：文件头探测、SQLite 曲库、标签读取，以及基于
   Symphonia/`opus-pure`/`wavicle`/`ape-decoder` 的解码。
2. 歌单与专辑。
3. 可选的 Apple Music 集成：把 Music 资料库合并进 Voanisa，并提供显式的
   导入/移除操作。
4. WMA 与 DSD 在出现合适的纯 Rust 解码器之前保持不支持；Voanisa 不会打包
   或调用 ffmpeg。

## Rust 核心（进行中）

- `Rust/voanisa-core` —— 文件头探测、SQLite 存储、曲库 CRUD，以及 Ogg、Opus、
  WavPack、APE 的流式 PCM 解码
- `Rust/voanisa-ffi` —— 返回 JSON 的 C ABI，以静态库链接
- Xcode 每次构建前自动运行 `Scripts/build-rust.sh`
- 测试：`cargo test --manifest-path Rust/Cargo.toml --workspace`

其余 Swift 核心仍不依赖 SwiftUI 与 AppKit，可以按模块逐步迁移。

## 许可证

MIT，详见 [LICENSE](LICENSE)。
