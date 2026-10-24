# 交接说明：Windows 协作者

这个目录由 **Windows 协作者** 负责构建与验证。macOS 侧（本仓库的主要开发环境）无法编译 WinUI 3，所以这里的代码是"按官方结构写、待 Windows 上验证"的状态。

请先读完这份文件再动手。

## 两个协作者

| 称呼 | 是谁 | 负责 |
|---|---|---|
| **macOS 协作者** | 本仓库主开发者 + macOS 上的 AI 助手 | `Rust/` 核心、`Voanisa/`（SwiftUI）、`apps/web/`、发版与官网 |
| **Windows 协作者** | Windows 机器上的开发者 + 那边的 DeepSeek | `apps/windows/`（WinUI 3）：构建、修编译错、验证 UI 与播放、补 Windows 集成 |

两边是**平级协作**，不区分"人"和"AI"——统一按协作者沟通。跨机器沟通只有两个渠道：

1. **Git 提交信息**（`main` 分支，及时推送）
2. **[SYNC.md](SYNC.md)**：往来记录，双方按模板追加条目

契约有变化时，macOS 协作者会在提交信息里带 `[contract]` 前缀，并在 `SYNC.md` 记一条；Windows 协作者每轮验收后也记一条（通过/失败 + 日志摘要）。

## 你的职责

- 在 **本目录内** 修复编译问题、跑起来、验证 UI 与播放
- 把发现的问题与修复提交回 `main`（见「回传」）
- **不要修改** `Rust/voanisa-core`、`Rust/voanisa-ffi`、`Voanisa/`（macOS）、`apps/web/` —— 它们由各自平台维护。若确实需要改核心，先在 `SYNC.md` 提出来，等 macOS 协作者确认，并在提交信息里写明理由

## 环境

| 项目 | 版本 |
|---|---|
| 系统 | Windows 10 19041+ 或 Windows 11 |
| .NET SDK | 8.0 |
| Visual Studio 2022 | 勾选「Windows 应用 SDK C# 模板」+ Windows 11 SDK |
| Rust | `rustup`，MSVC toolchain（`rustup default stable-msvc`） |

## 构建与运行

```powershell
cd apps\windows
powershell -ExecutionPolicy Bypass -File build.ps1
```

脚本做两件事：`cargo build -p voanisa-ffi --release`，然后 `dotnet build`。

产物：`bin\Debug\net8.0-windows10.0.19041.0\win-x64\Voanisa.Windows.exe`

若提示找不到 `voanisa_ffi.dll`，把它从 `Rust\target\release\` 复制到 exe 同目录。

若提示缺少 Windows App Runtime，二选一：

```xml
<!-- Voanisa.Windows.csproj -->
<WindowsAppSDKSelfContained>true</WindowsAppSDKSelfContained>
```

或安装 [Windows App Runtime](https://learn.microsoft.com/windows/apps/windows-app-sdk/downloads)。

## 契约：这些不要改

1. **曲库路径**
   ```
   %USERPROFILE%\Music\Voanisa\
   ├── library.sqlite
   ├── Media\<file_name>
   └── Covers\Rendered\<cover_file_name>
   ```
   环境变量 `VOANISA_LIBRARY` 可覆盖根目录（与 macOS / Tauri 版同一个约定）。

2. **C ABI**（`Rust/voanisa-ffi`，导出为 `voanisa_ffi.dll`）
   当前用到的是：
   ```c
   const char* voanisa_core_version(void);
   char*       voanisa_tracks_json(const char* db_path, const char* query);
   void*       voanisa_decoder_open(const char* path);
   char*       voanisa_decoder_info_json(void* decoder);
   int64_t     voanisa_decoder_read(void* decoder, float* out, uint32_t frames);
   int32_t     voanisa_decoder_seek(void* decoder, double seconds);
   double      voanisa_decoder_position(void* decoder);
   void        voanisa_decoder_close(void* decoder);
   void        voanisa_string_free(char* value);
   ```

3. **JSON 信封**
   ```json
   { "ok": true,  "data": [ ... ] }
   { "ok": false, "error": { "message": "...", "code": "..." } }
   ```

4. **一种解码路径**
   播放必须通过 `voanisa_decoder_*` 取 PCM。**不要**引入 Media Foundation / ffmpeg 直接解码文件——那会让 Windows 版与 macOS 版的行为分叉，这是项目的设计承诺。

## 已知未验证点（按可能性排序）

| # | 位置 | 可能的问题 |
|---|---|---|
| 1 | `Voanisa.Windows.csproj` | `Microsoft.WindowsAppSDK` 用浮动版本 `1.6.*`；若 NuGet 解析失败，改成当前稳定版号 |
| 2 | `MainWindow.xaml` | `ThemeResource` 键名（`LayerFillColorDefaultBrush`、`CardStrokeColorDefaultBrush`）在旧版本可能不存在，报错就换 `SystemControlBackgroundBaseLowBrush` 之类 |
| 3 | `Core/Player.cs` | `chain.ToWaveProvider()` 扩展方法与 `WdlResamplingSampleProvider` 的命名空间；NAudio 2.x 里在 `NAudio.Wave.SampleProviders` |
| 4 | `Core/Player.cs` | 固定重采样到 48 kHz 是近似做法；真实设备若是 44.1 kHz 需要改成读取 `WasapiOut` 的混音格式 |
| 5 | `MainWindow.xaml` | `x:Bind Cover`（`ImageSource`）在 DataTemplate 里的编译绑定，个别版本要求 `x:DataType` 完全匹配 |
| 6 | `Core/VoanisaCore.cs` | `LibraryRoot` 依赖 `SpecialFolder.UserProfile`，若被 OneDrive 重定向需确认 |

## 验收标准

跑通下面这一串才算完成第一轮：

- [ ] `build.ps1` 全绿，exe 能启动
- [ ] 窗口有 **Mica** 背景，深/浅色切换跟随系统
- [ ] 列表显示曲库全部歌曲：封面、标题、艺术家、时长
- [ ] 点一行能播放，2 秒内出声
- [ ] 播放/暂停、上一首、下一首行为正确（列表首尾不环绕）
- [ ] 拖动进度条能跳转，进度随播放前进
- [ ] 关闭窗口后进程退出、没有残留线程

## 回传

1. 改动提交到 `main`（描述里写清"仅 Windows"）
2. 在 [SYNC.md](SYNC.md) 追加一条记录，附 `dotnet --info` 与构建日志的关键片段
3. 若某处为了编译通过做了**功能降级**（例如临时删掉播放），必须在提交信息与 SYNC.md 里明确写出，方便 macOS 协作者同步认知

## 下一步（按优先级）

1. **SMTC**：`SystemMediaTransportControls` —— 音量键、锁屏、耳机按键。这是 Windows 上"像正经播放器"的分水岭
2. **任务栏缩略图按钮**：上一首 / 播放 / 下一首
3. `Alt+←` / `Alt+→` 切歌（`KeyboardAccelerator`）
4. 导入与元数据编辑：接 `voanisa_probe_json` / `voanisa_insert_track_json` / `voanisa_write_tags_json`
5. 删除：接入回收站（`Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile` 带 RecycleOption）后再调 `voanisa_delete_track_json`
6. MSIX 打包与签名（否则 SmartScreen 会警告）
