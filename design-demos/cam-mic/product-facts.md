# v5xs 摄像头/麦克风占用检测 · 产品事实

> 设计方案的可行性依据；由 macnotetaker.com（生产实践）与 objective-see.org（OverSight，成熟开源产品）一手来源核对。

## 开关状态（已确认事实，非猜想）

- **macOS 系统自带「绿色/橙色」状态指标**：摄像头在用显绿点，麦克风在用显橙点，菜单栏可看到「哪个 App 在用」。但系统不提供「正在用哪个进程」的公共、稳定的 API。
- **成熟开源参考 OverSight**（objective-see，macOS 12+，开源）：能检测「哪类 App 正在用摄像头或麦克风」。其机制：
  - **摄像头**：监控 IOKit 的摄像头 nub 事件（WebcamDALExtension / VDCAssistant 等），从属性/调用栈识别访问进程。
  - **麦克风**：用 CoreAudio「进程对象(process objects)」监控每个进程的 `kAudioDevicePropertyDeviceIsRunningSomewhere` 等属性，识别谁在采集。
- **macOS 14.2+ 新增 CoreAudio process-tap（进程对象）家族**：能给出「每个进程的音频采集状态」，是「精确知道用的是哪个 App」的较新途径。macnotetaker 用它做生产：监听默认输入设备的“是否有进程在跑” + 进程对象列出具体采集进程。注意它需要更新到 macOS 14.2+，且浏览器会通过 helper 进程采集、需排除自身。
  - 出处：macnotetaker.com/blog/which-app-is-using-mic-coreaudio-process-objects
  - 出处：developer.apple.com/documentation/coreaudio/kAudioProcessPropertyIsRunning

## 对本设计的影响

- **技术上可行**：v5xs 可以做到「检测相机/麦克风当前是否被占用、占用方是哪个进程（多数情况）」——参考 OverSight 思路：cam 走 IOKit nub 监控，mic 走 CoreAudio 进程对象（macOS 14.2+，v5xs 最低已是 macOS 14）。
- **边界一**：进程级精确识别并非 100%——尤其浏览器（通过 helper）与系统进程；OverSight 实际也会对「未知访问」给出笼统提示。设计上要诚实：显示「正在用」+ 多数时候能给出进程名；无法识别时显示「有其他进程在访问」。
- **边界二**：需要轮询/监听 IOKit 与 CoreAudio，属于常驻监控，功耗与权限需考虑。app 自身要排除（避免「自己看自己」）。
- **边界三**：macOS 14.2 以下没有进程级 mic 识别，只有「设备级某进程在采集」的布尔；cam 无系统统一 API。设计要能优雅降级。

## 设计要呈现什么（诚实）

- 相机：● 绿点 在用（附进程名，若可识别）｜○ 空闲
- 麦克风：● 橙点 在用（附进程名，若可识别）｜○ 空闲
- 无法识别进程时：显示「有其他进程正在访问」，不给假的进程名
- 可选：最近占用记录
## 真实代码验证（本机实测，2026-10-25）

- **麦克风：已在本机跑通**。用 CoreAudio 进程对象（`kAudioHardwarePropertyProcessObjectList`）枚举出 30 个音频进程，
  并正确读到 `kAudioProcessPropertyIsRunningInput/Output`。实测检测到 `com.apple.WebKit.GPU` 正在输出音频（output=1）。
  也就是说：**麦克风检测是真实可用、能精确到进程 bundle id 的**。
- **摄像头：macOS 无公开的「按进程归属」API**。Apple Silicon 上摄像头由系统守护进程 `appleh13camerad`(pid 546) 统一接管，
  任何 App 都是它的 client；没有像 CoreAudio 那样的进程级画像。OverSight 在 Apple Silicon 上对「精确到哪个 App」也受限。
  因此摄像头只能做到：**「在用 / 空闲」设备级近似 + 尽力归属；归属不到时如实显示「有其他进程正在访问」**。
- **权限**：读取 CoreAudio 进程对象 **不需要麦克风权限**（只是枚举，不录音）；我们也不主动打开摄像头，
  因此**无需在 Info.plist 里加摄像头/麦克风 usage 描述、也不会触发权限弹窗**。

## 定稿工程范围

- 麦克风：真实检测 + 进程名（bundle id → 显示名）。
- 摄像头：`在用/空闲` 近似检测（尽力），归属不到进程时显示「有其他进程正在访问」。
- Privacystrip UI（方向三）插到 batteryCard 与 processCard 之间。

## 修正：摄像头检测改用官方 API（2026-10-25 二轮）

用户反馈第一版摄像头是误报（微信在运行就显示"在用"）。已修正：

- **不再用"进程名匹配"当占用信号**。那会在"某类 App 在运行"时误报，对隐私工具不可接受。
- **改用官方公开 AVCaptureDevice.isInUseByAnotherApplication**：这是 Apple 专门反映"当前是否有其他应用正占用摄像头"的布尔属性。本机干净环境实测返回 false（正确）。
- 摄像头占用时，因 macOS 无按进程归属摄像头的公开 API，**不编造应用名**，UI 显示"有其他进程在访问"。
- 麦克风保持真实：CoreAudio 进程对象精确到进程 bundle id（本机实测可用）。

验证结果：
- 干净环境: micInUse=false, camInUse=false（正确，无人使用）；不再误报微信/自动填充等进程。
- build-app.sh / test-local.sh 全部通过。
