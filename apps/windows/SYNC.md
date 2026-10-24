# 往来记录（Windows ↔ macOS）

两个协作者的跨机器沟通日志。**只追加，不改写历史**；每次提交带一条记录，方便对方在下一台机器上看到上下文。

- **macOS 协作者**：核心、SwiftUI、Tauri、发版
- **Windows 协作者**：`apps/windows/`（WinUI 3）

## 模板

```markdown
## YYYY-MM-DD · 谁 → 谁
**状态**：构建通过 / 构建失败 / 验收通过 / 契约变更 / 阻塞
**环境**：（Windows 侧写 `dotnet --info` 摘要；macOS 侧写 Xcode / Rust 版本）
**内容**：做了什么、看到什么现象
**日志**：（关键错误行，不要贴整份日志）
**需要对方**：无 / 修改契约 / 提供接口 / 确认行为
```

---

## 2026-10-24 · macOS → Windows

**状态**：骨架已交付，等待首次构建

**环境**：macOS 26 / Xcode 16.4 / Rust 1.98.1（无法编译 WinUI 3）

**内容**：
- 新建 `apps/windows/`：WinUI 3 unpackaged 工程、Mica 背景、NavigationView 侧栏、`ListView` 曲库列表、播放条（播放/暂停、上一首/下一首、进度拖动）
- `Core/VoanisaCore.cs`：P/Invoke 调 `voanisa_ffi.dll` 读曲库（`voanisa_tracks_json`）
- `Core/Player.cs`：Rust 解码 → NAudio WASAPI，48 kHz 重采样
- `build.ps1`：先 `cargo build -p voanisa-ffi --release`，再 `dotnet build`
- 契约写在 `AGENTS.md`：曲库路径、C ABI、JSON 信封、"一种解码路径"

**日志**：无（本机无法编译）

**需要对方**：在 Windows 上跑 `build.ps1`，把首次编译错误与 `dotnet --info` 摘要记到下一条。按 `AGENTS.md` 的「已知未验证点」顺序排查：csproj 版本 → XAML 资源键 → NAudio 扩展方法。
