# Voanisa for Windows (WinUI 3)

Windows 端的原生界面：WinUI 3 + Windows App SDK，配合共享的 Rust 核心。

> **本目录由 Windows 侧协作者负责构建与验证。** 动手前先读 [AGENTS.md](AGENTS.md)：里面写清了环境、契约（曲库路径 / C ABI / JSON 信封 / 一种解码路径）、已知未验证点、验收清单与回传方式。
>
> **状态：骨架代码，尚未在 Windows 上编译验证过。** 第一次 `dotnet build` 可能仍有需要微调的地方（例如 Windows App SDK 版本、XAML 资源键），把报错贴回来即可。

## 结构

```
apps/windows/
├── Voanisa.Windows.csproj    unpackaged WinUI 3 工程
├── App.xaml / App.xaml.cs
├── MainWindow.xaml / .cs     Mica 背景 + NavigationView + 列表 + 播放条
├── Core/
│   ├── VoanisaCore.cs        P/Invoke → voanisa_ffi.dll，读取曲库
│   └── Player.cs             Rust 解码 → WASAPI 输出（NAudio）
└── build.ps1
```

界面用到的 WinUI 能力：**Mica 背景**（`SystemBackdrop`）、`NavigationView` 侧栏、`ListView` 自带 UI 虚拟化、Segoe UI Variable、系统深浅色主题资源（`ThemeResource`）。

## 前置条件

1. **.NET 8 SDK**
2. **Visual Studio 2022**（或 Build Tools）勾选「Windows 应用 SDK C# 模板」与 Windows 11 SDK
3. **Rust 工具链**（`rustup`），且已安装 MSVC target
4. **Windows App Runtime**：工程是 unpackaged 的，直接跑 exe 需要系统里装了 Windows App Runtime；
   或者给 `csproj` 加一行让它自带运行时（体积 +约 50 MB）：

   ```xml
   <WindowsAppSDKSelfContained>true</WindowsAppSDKSelfContained>
   ```

## 构建

```powershell
cd apps\windows
powershell -ExecutionPolicy Bypass -File build.ps1
```

脚本会先 `cargo build -p voanisa-ffi --release` 产出 `Rust\target\release\voanisa_ffi.dll`，再 `dotnet build`。

产物：`apps\windows\bin\Debug\net8.0-windows10.0.19041.0\win-x64\Voanisa.Windows.exe`

> `voanisa_ffi.dll` 需要和 exe 同目录。如果运行时提示找不到 DLL，手动从
> `Rust\target\release\voanisa_ffi.dll` 复制过去即可（后续可以加到 csproj 的 `Content` 里自动复制）。

## 曲库位置

与 macOS 版完全一致：`%USERPROFILE%\Music\Voanisa\`

```
library.sqlite
Media\<file_name>
Covers\Rendered\<cover_file_name>
```

设置环境变量 `VOANISA_LIBRARY` 可指向别的目录（与 Swift/Tauri 版同一个约定）。

## 已经实现的

- 读取曲库并列表显示（封面、标题、艺术家、时长）
- 双击（或单击选中后点播放）播放
- 播放 / 暂停、上一首 / 下一首
- 进度条显示与拖动 seek
- Mica 背景、系统主题色、NavigationView 侧栏

## 还没做的

- 导入、元数据编辑、封面更换、歌单
- 删除（需要接入回收站 API）
- **SMTC**（系统媒体控制中心）：`SystemMediaTransportControls`，对应 macOS 的 Now Playing
- 任务栏缩略图按钮、Jump List、文件关联
- MSIX 打包与签名
- Alt+← / Alt+→ 切歌（键盘加速器要挂到窗口内容上，参考 `KeyboardAccelerator`）

## 与其它平台的关系

```
Rust/voanisa-core   ← 三端共用，唯一解码路径
Rust/voanisa-ffi    ← SwiftUI(macOS) 与 C#(Windows) 共用
apps/windows        ← 本工程
apps/web            ← Tauri 版，给 Linux 兜底
Voanisa/            ← macOS SwiftUI
```
