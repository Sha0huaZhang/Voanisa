<div align="center">
    <img src="images/Voanisa-icon-1024.png" alt="Logo" width="256" />
    <h1>Voanisa</h1>
</div>

# Voanisa

为 macOS 打造的本地音乐库，视觉风格向 Elysia 靠拢。

[English](./README.md) · **简体中文**

本仓库包含 **0.1.0 原型**。每个导入的音频文件都会成为曲库中的一首歌曲。
音频会被复制进自包含的曲库，由用户命名、配上正方形封面，并在本机播放——
不依赖 Apple Music，也不会在曲库之外写入任何文件。

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

### 原型支持的格式

MP3、AAC/ADTS、M4A、ALAC、FLAC、WAV、AIFF、CAF。

MP4/MOV 会作为纯音频 M4A 导入，视频轨道会被丢弃。

Ogg Vorbis、Opus、WMA、APE、WavPack、DSF/DFF、Matroska/WebM 可以被识别，
但会提示暂不支持；它们是后续 Rust 解码层的目标。

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

1. Rust 可移植核心：文件头探测、SQLite 曲库、标签读写、用 Symphonia
   解码 Ogg/Opus/WavPack。
2. 歌单与专辑。
3. 可选的 Apple Music 集成：把 Music 资料库合并进 Voanisa，并提供显式的
   导入/移除操作。
4. 可选的 FFmpeg 模块，用于 WMA/APE/DSD。

## Rust 核心（进行中）

- `Rust/voanisa-core` —— 文件头探测、SQLite 存储与曲库 CRUD
- `Rust/voanisa-ffi` —— 返回 JSON 的 C ABI，以静态库链接
- Xcode 每次构建前自动运行 `Scripts/build-rust.sh`
- 测试：`cargo test --manifest-path Rust/Cargo.toml --workspace`

其余 Swift 核心仍不依赖 SwiftUI 与 AppKit，可以按模块逐步迁移。

## 许可证

MIT，详见 [LICENSE](LICENSE)。
