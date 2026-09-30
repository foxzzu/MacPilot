# PilotNest 远程画面实施与验收

## 使用方式

控制页的「远程控制」在上方显示实时画面。画面区域、画面留黑边和下方空白区域
共用一个连续的 TrackpadView，复用 RemoteTrackpadModel、压力引擎与文本输入链路。
除画面区域的双指捏合缩放外，触摸均模拟鼠标触控板：单指相对移动、轻点点击当前鼠标位置、拖拽、多指滚动；
触摸画面不会把鼠标跳到手指对应的屏幕坐标。手指跨过画面与下方区域边界时，
仍由同一个触控视图追踪，不会重新开始手势。

默认画面占内容区域 45%；键盘打开后画面占键盘上方内容区域 85%，画面仍可模拟
触控板操作鼠标，收起键盘后同样可用。ESC、TAB、CTRL、OPTION、CMD、删除、
视频重试按钮及系统键盘保留独立操作，不发送触控板手势。修饰键作用于下一次
ASCII 字母/数字或快捷键，可执行 CMD+A/C/V 等操作。
方向按钮显式切换竖屏 / 横屏，不读取陀螺仪，不改变独立触控板的旋转规则。

显示器菜单默认选主屏，允许切换其他显示器；切换时销毁旧视频会话、重新协商。
相对触控板输入仍由 WindowServer 处理。BLE 只提供触控板与键盘，画面区域明确说明限制。

画面支持 1–4 倍双指捏合缩放。缩放围绕捏合位置，识别后取消当前触控板手势，
不会继续向 Mac 发送鼠标或滚动事件。双指同向移动仍模拟 Mac 滚动；下方区域
保留原有触控板行为。缩放仅作用于手机预览，不改变 Mac 光标或视频编码。
顶部「还原画面缩放」按钮恢复原始视图，切换显示器时自动还原。

## 架构与安全

- 控制 / 二进制输入继续走原有加密连接和序列空间，帧标签 0x03 不变。
- 新 clientHello 的可选 `features: ["remoteDesktop", "dockGroups"]` 被旧 Mac 忽略。新 Mac 只向
  声明对应 feature 的客户端返回 `.remoteDesktop` / `.dockGroups` 能力，避免旧手机解码未知枚举失败。
- 画面开始由加密 `beginRemoteVideo` 控制命令协商，响应包含独立临时 TCP 端口、
  随机 32 字节一次性密钥、显示器列表。BLE 会被服务端直接拒绝。
- 视频不使用 RemoteRequest，不复用输入发送队列；TCP 使用 includePeerToPeer，
  连接同一已解析 Mac 地址（保留 AWDL 的 IPv6 scope）。
- 视频双向各用独立 HKDF 密钥、ChaChaPoly 和严格递增序列。第一包必须是成功解密的
  hello；此前不启动采集。未认证连接 10 秒超时，控制连接关闭时销毁全部资源。
- 每包格式：u32 BE 长度 | u64 BE 序列 | ChaChaPoly combined。加密明文为
  u8 类型 | i64 BE Unix 毫秒 | payload。类型 1 hello / 2 config / 3 keyFrame /
  4 deltaFrame / 5 feedback / 6 diagnostics / 7 focus。长度上限 2 MiB。
- H.264 payload：u16 SPS长度 | SPS | u16 PPS长度 | PPS | AVCC（4字节 NAL长度）。
  每个 IDR 重复 SPS/PPS；delta 参数集为空。接收端校验 NAL 边界与参数集长度。
- 捕获、编码、网络、AX 焦点查询各有后台队列；不在主线程编码，不用 JPEG、UIImage
  或 SwiftUI 每帧刷新。播放器使用 VTDecompressionSession 与 AVSampleBufferDisplayLayer。
- VideoFrameBuffer 只持有最新解码表面。发送只保留一包在途；拒绝视频帧后强制下一帧
  为 IDR，不排队重播过期画面。8 秒发送超时、TCP keepalive 和首次画面超时负责恢复。
- 默认上限 1280×720 / 30 FPS / 2 Mbps，按源屏幕比例缩放并取偶数尺寸。
  关闭帧重排，H.264 Main/CABAC，关键帧间隔 1 秒。
  每 8 秒根据完成发送耗时 / 解码反馈调整：低档 960×540 / 20 FPS / 1 Mbps；
  高档 1920×1080 / 30 FPS / 4 Mbps。这是传输拥塞启发式，不代表链路带宽测量。
- AX 焦点监测每 500 ms 在独立队列查询，只发送焦点变化；键盘打开重新验证并绑定
  当前可编辑元素。普通触控板点击仍使用原有指针命中检测。每次文本操作继续校验
  绑定元素的焦点，IME 未提交文本留在手机。
- 保留旧协议的绝对坐标点击命令以兼容旧客户端；当前手机页面统一使用相对触控板输入。
  输入与快捷键经过认证、会话已武装和 Accessibility 检查；不接受任意 CGKeyCode。

## 恢复与权限

离开页面、App 后台、断线、切换显示器均释放解码器和视频连接。前台 / 控制连接
恢复后重新协商；捕获或视频连接失败会重试，触控板保持独立。缺少 Accessibility 或输入断线时，页面显示输入错误与重试按钮，键盘按钮仅在输入
就绪时可用。视频 socket 取消后忽略尚未交付的接收回调，防止旧解码器被重新启动。
首次缺少屏幕录制
授权显示操作提示，授权后手动重试，不循环弹权限。

Mac 显示器关闭时继续尝试 ScreenCaptureKit；不同系统、锁屏、安全内容与显示器
硬件可能停止提供画面，不能保证黑屏或登录窗口仍可见。失败时显示可恢复状态，
保留原有唤醒、解锁和输入功能。

## 文件变更分组（四个阶段合并验收）

1. 采集、编码、传输、播放：共享 RemoteVideoProtocol / RemoteH264Frame /
   RemoteVideoTransport；Mac Video/ 的 RemoteVideoSession、RemoteScreenCapture、
   RemoteVideoEncoder；iOS RemoteDesktop/ 的 RemoteVideoDecoder、RemoteVideoView、
   VideoFrameBuffer。RemoteCommand、RemoteModels、握手和连接管理负责协商与能力门控。
2. 输入和键盘：RemoteDesktopView、RemoteDesktopState、HomeView 入口；
   RemoteKeyboardFocusMonitor、RemoteTextInputController 的可选焦点绑定；
   RemoteTrackpadModel 只开放已有键盘请求入口并传递焦点选项，手势 / 压力核心未改。
   RemoteKeyboardInputView 增加使用当前 scene 方向的选项，默认行为保持原样。
3. 画面点击、光标、多屏：RemoteDesktopInput 的归一化坐标映射与白名单快捷键；
   showsCursor；显示器列表 / 选择与对应会话重建。
4. 自适应与诊断：编码队列质量调整；显式方向按钮；诊断显示 FPS、编码 / 解码耗时、
   接收 kb/s、源端与解码端丢帧、控制 RTT。中英文文案同步。

## 当前验证证据与限制

- 共享包 68 项测试通过，包括方向密钥隔离、错误票据、重放、篡改、截断帧、分片 / 切片、
  旧控制响应兼容。独立视频 socket 测试完成 hello 和加密数据往返；同一队列连续
  尝试发送 100 包只接受 1 包，证明没有无界发送积压。
- 720p 合成表面硬件编码 30 帧：合并后测试平均 3.20 ms，峰值 12.87 ms；
  同进程 CPU 为单核的 11.1%。测试以尽快编码的方式运行，包含测试进程开销，
  不包含屏幕采集、真实无线传输、解码或显示，不能作为整机常驻 CPU 数据。
- macOS 全量测试串行运行 948 项通过（合并上游后）。并行运行触发仓库已记录的四项时序失败，
  另有 ResourceLifecycleTests 全局任务计数被其他 suite 改动；串行全量无失败。
- macOS Release warnings-as-errors、iOS Simulator 双架构及签名 iphoneos 构建通过。
  模拟器首页已目视确认入口布局；真机远程画面、方向、键盘与多指操作仍需实机验收。
- 控制 RTT 是往返链路指标，不是输入至可见光标延迟。现有 Trackpad / RemoteInput
  日志提供 touchToSend / receiveToInject 分段；未声称达到 <30 ms 输入或 <100 ms
  画面端到端目标，需高速摄影测量。

## 真机验收矩阵

LAN 和 AWDL 各运行 30 分钟：移动 / 点击 / 拖拽 / 多指滚动 / 压力，观察段延迟、
FPS、编码解码耗时、CPU 和丢帧；同时录制高速摄影对照实际输入响应。
测试输入框、IME、CMD+A/C/V、切换非编辑内容、手动关闭键盘；横竖屏与 iPad；
键盘展开 / 收起时在画面、留黑边、下方空白区移动 / 点击 / 多指滚动，以及跨区域拖拽；
测试画面双指缩放、边界裁切、还原按钮、缩放后键盘切换和双指滚动；
确认捏合不会产生 Mac 点击、持续拖拽或滚动，触摸画面不跳转鼠标位置，快捷键与重试按钮不产生鼠标事件；Retina、多屏负坐标；网络拥塞、网络切换、BLE 降级；Mac 睡眠 / 唤醒、
手机后台 / 前台；撤销屏幕录制权限、关闭显示器和捕获失败后的恢复。
