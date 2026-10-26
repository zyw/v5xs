import AppKit
import Charts
import MonitorCore
import SwiftUI

private enum Palette {
    static let background = Color(red: 0.12, green: 0.16, blue: 0.15)
    static let card = Color(red: 0.17, green: 0.22, blue: 0.19)
    static let mint = Color(red: 0.57, green: 0.86, blue: 0.72)
    static let blue = Color(red: 0.52, green: 0.75, blue: 0.92)
    static let amber = Color(red: 0.96, green: 0.78, blue: 0.52)
    static let muted = Color(red: 0.64, green: 0.71, blue: 0.67)
    /// 进程榜正文用的暗色：比 muted 明显下沉，避免列表在深色卡片上过于抢眼，
    /// 但仍与卡片底色保持 4.66:1 对比度（WCAG AA 小字下限），不至于看不清。
    static let dim = Color(red: 0.58, green: 0.64, blue: 0.61)
    /// 鼠标经过进程行时的行底色（叠加在卡片上的一点提亮）。
    static let rowHover = Color.white.opacity(0.07)
}

struct MonitorPanel: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var updates: UpdateChecker
    @Environment(\.localization) private var loc
    let onOpenSettings: () -> Void
    let onOpenUninstaller: () -> Void
    @State private var headerHovering = false
    private var chartPoints: [NetworkPoint] {
        let start = Date().addingTimeInterval(-60)
        return store.networkHistory.filter { $0.time >= start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            HStack(spacing: 7) {
                cpuCard
                gpuCard
            }
            HStack(spacing: 7) {
                memoryCard
                diskCard
            }
            HStack(alignment: .top, spacing: 7) {
                networkCard
                thermalCard
            }
            batteryCard
            privacyStrip
            processCard
            HStack {
                Button(loc.t(.settings), action: onOpenSettings)
                Spacer()
                // 版本号与刷新频率都会变，用 %@ 占位让各语言自行排版。
                Text(loc.t(.footerFormat,
                           updates.currentVersionText,
                           store.refreshRate.shortDescription))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button(loc.t(.quit)) { NSApp.terminate(nil) }
            }
            .font(.system(size: 10))
            .buttonStyle(.plain)
            .padding(.horizontal, 5)
        }
        .padding(10)
        .frame(width: 430, alignment: .top)
        .background(Palette.background)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.amber)
                Text(store.healthScore.map(String.init) ?? "—")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text(store.healthScore.map(HealthScore.label(for:)) ?? loc.t(.healthCollecting))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                Spacer()
            }
            HStack(spacing: 5) {
                badge(store.chipName ?? loc.t(.chipUnknown))
                badge("\(store.machine.memoryBytes / 1_073_741_824) GB")
                let version = ProcessInfo.processInfo.operatingSystemVersion
                badge("macOS \(version.majorVersion).\(version.minorVersion)")
                let uptime = store.machine.bootTime.flatMap {
                    UptimeText.describe(seconds: Date().timeIntervalSince($0))
                } ?? loc.t(.notAvailable)
                badge(uptime)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(headerHovering ? Palette.mint.opacity(0.55) : .clear, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if headerHovering {
                Text(loc.t(.softwareUninstallArrow))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.mint)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Palette.background.opacity(0.82), in: Capsule())
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onTapGesture { onOpenUninstaller() }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { headerHovering = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(loc.t(.openUninstallerHint))
        .help(loc.t(.uninstallHint))
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }

    private var cpuCard: some View {
        MetricCard(title: loc.t(.cpu), accessory: cpuCoreText) {
            Text(store.cpu.map { "\(Int($0.rounded()))%" } ?? loc.t(.notAvailable))
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Chart(store.cpuHistory.suffix(60)) { point in
                LineMark(x: .value(loc.t(.timeAxis), point.time),
                         y: .value(loc.t(.usageAxis), point.value))
                    .foregroundStyle(Palette.mint)
                    .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 21)
        }
    }

    private var cpuCoreText: String {
        if let performance = store.machine.performanceCores,
           let efficiency = store.machine.efficiencyCores {
            return loc.t(.coresPerfEff, store.machine.cpuCores, performance, efficiency)
        }
        return loc.t(.coresLabel, store.machine.cpuCores)
    }

    private var gpuCard: some View {
        MetricCard(title: loc.t(.gpuActivity),
                   accessory: store.gpuCores.map { loc.t(.coresLabel, $0) } ?? loc.t(.gpuCoresUnknown)) {
            Text(store.gpuUsage.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 25, weight: .bold, design: .rounded))
            if store.gpuUsage != nil {
                Chart(store.gpuHistory) { point in
                    LineMark(x: .value(loc.t(.timeAxis), point.time),
                             y: .value(loc.t(.usageAxis), point.value))
                        .foregroundStyle(Palette.blue)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 21)
                .accessibilityLabel(loc.t(.gpuActivityHistory))
            } else {
                Text(loc.t(.gpuNotAvailable))
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 21, alignment: .bottomLeading)
                    .lineLimit(2)
            }
        }
    }

    private var memoryCard: some View {
        MetricCard(title: loc.t(.memory), accessory: "") {
            Text(store.memoryUsed.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—")
                .font(.system(size: 19, weight: .bold, design: .rounded))
            ProgressView(value: min(Double(store.memoryUsed ?? 0) / Double(max(store.machine.memoryBytes, 1)), 1))
                .tint(Palette.mint)
                .controlSize(.mini)
            Text(loc.t(.totalLabel,
                        ByteCountFormatter.string(fromByteCount: Int64(store.machine.memoryBytes), countStyle: .memory)))
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
        }
    }

    private var diskCard: some View {
        MetricCard(title: loc.t(.freeSpace), accessory: store.diskTotal.map {
            loc.t(.totalLabel, ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))
        } ?? loc.t(.totalLabel, loc.t(.notAvailable)), symbol: "internaldrive") {
            Text(store.diskAvailable.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                .font(.system(size: 19, weight: .bold, design: .rounded))
            ProgressView(value: diskUsedFraction)
                .tint(Palette.blue)
                .controlSize(.mini)
                .accessibilityLabel(loc.t(.diskUsedA11y))
                .accessibilityValue("\(Int(diskUsedFraction * 100))%")
            Text(loc.t(.readWrite, rate(store.diskRead), rate(store.diskWrite)))
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var diskUsedFraction: Double {
        guard let total = store.diskTotal, let available = store.diskAvailable, total > 0 else { return 0 }
        return min(1, max(0, 1 - Double(available) / Double(total)))
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "globe").foregroundStyle(Palette.blue)
                Text(loc.t(.network)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                badge(store.networkType)
            }
            Text(rate(store.download))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel(loc.t(.downloadRateA11y, rate(store.download)))
            if chartPoints.isEmpty {
                Text(loc.t(.waitingNetwork))
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 30)
            } else {
                Chart {
                    ForEach(chartPoints) { point in
                        LineMark(x: .value(loc.t(.timeAxis), point.time),
                                 y: .value(loc.t(.downloadAxis), point.download))
                            .foregroundStyle(Palette.mint)
                        LineMark(x: .value(loc.t(.timeAxis), point.time),
                                 y: .value(loc.t(.uploadAxis), point.upload))
                            .foregroundStyle(Palette.blue)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 30)
                .accessibilityLabel(loc.t(.networkCurveA11y))
            }
            HStack {
                Text(loc.t(.uploadRate, rate(store.upload)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                // 刷新频率已移到设置页统一配置；这里只做状态展示，
                // 避免同一设置出现两个入口、两处状态可能不同步。
                Text(loc.t(.footerFormat, loc.t(.refresh), store.refreshRate.title))
                    .lineLimit(1)
                    .help(loc.t(.refreshRateA11y))
            }
            .font(.system(size: 9))
            .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 98, alignment: .topLeading)
        .panel()
    }

    private var thermalCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "thermometer.medium").foregroundStyle(Palette.mint)
                Text(loc.t(.temperature)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                badge(store.thermalDescription)
            }
            Text(temperature(store.cpuTemperature))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .accessibilityLabel(loc.t(.cpuTempA11y, temperature(store.cpuTemperature)))
            ProgressView(value: min(max((store.cpuTemperature ?? 0) / 110, 0), 1))
                .tint(Palette.mint)
                .controlSize(.mini)
                .frame(height: 30)
                .accessibilityLabel(loc.t(.cpuTempRatioA11y))
                .accessibilityValue(temperature(store.cpuTemperature))
            Text(loc.t(.footerFormat, loc.t(.gpu, temperature(store.gpuTemperature)),
                        store.chipName ?? loc.t(.notAvailable)))
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 98, alignment: .topLeading)
        .panel()
    }

    /// 隐私条（方向三）：摄像头 / 麦克风占用状态，夹在「电量」与「高占用进程」之间。
    private var privacyStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.mint)
                .frame(width: 30, height: 30)
                .background(Palette.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle().fill(store.camInUse ? Palette.blue : Color.white.opacity(0.22)).frame(width: 7, height: 7)
                    Text(loc.t(.privacyCamera)).font(.system(size: 11, weight: .semibold)).foregroundStyle(store.camInUse ? Palette.blue : Palette.muted)
                }
                Text(store.camInUse ? (store.camProcess ?? loc.t(.privacyInUseByOther)) : loc.t(.privacyIdle))
                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle().fill(store.micInUse ? Palette.amber : Color.white.opacity(0.22)).frame(width: 7, height: 7)
                    Text(loc.t(.privacyMicrophone)).font(.system(size: 11, weight: .semibold)).foregroundStyle(store.micInUse ? Palette.amber : Palette.muted)
                }
                Text(store.micInUse ? (store.micProcess ?? loc.t(.privacyInUseByOther)) : loc.t(.privacyIdle))
                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(loc.t(store.camInUse ? .camInUse : .camIdle)).foregroundStyle(store.camInUse ? Palette.blue : Palette.muted)
                Text(loc.t(store.micInUse ? .micInUse : .micIdle)).foregroundStyle(store.micInUse ? Palette.amber : Palette.muted)
            }
            .font(.system(size: 10, weight: .semibold))
        }
        .padding(11)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }
    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(loc.t(.battery)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                Text(loc.t(.localAndPeripherals))
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.muted)
            }
            Divider().overlay(.white.opacity(0.1))
            // 垂直居中：两个电量环与左侧 MacBook 区块按中心线对齐，
            // 间距固定 14pt，避免环体缩小后挤在一起。
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacBook").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Text(store.batteryPercentage.map { "\($0)%" } ?? loc.t(.notAvailable))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(store.batteryStatus).font(.system(size: 9)).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider().frame(height: 44)
                HStack(spacing: 14) {
                    BatteryRing(symbol: "magicmouse.fill", name: loc.t(.mouse),
                                percentage: peripheral(kind: .mouse)?.percentage)
                    BatteryRing(symbol: "keyboard.fill", name: loc.t(.keyboard),
                                percentage: peripheral(kind: .keyboard)?.percentage)
                }
                .fixedSize()
                // 环缩小后右侧会多出空白，稍加右内边距让整体在卡片里居中。
                .padding(.trailing, 4)
            }
            // 显式指定居中，不依赖 HStack 默认对齐，避免日后改动布局时环体又被顶高。
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .panel()
    }

    private func peripheral(kind: PeripheralBattery.Kind) -> PeripheralBattery? {
        store.peripherals.first { $0.kind == kind }
    }

    private var processCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 与 ProcessRow 保持同一套水平内边距与列间距，否则「内存 / CPU」
            // 表头会和下面的数值列错开 5pt。
            HStack(spacing: 5) {
                Text(loc.t(.highUsageProcesses)).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(loc.t(.memoryColumn)).frame(width: 70, alignment: .trailing)
                Text(loc.t(.cpuColumn)).frame(width: 48, alignment: .trailing)
                Button { store.refreshProcesses() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.mint)
                    .frame(width: 22)
                    .accessibilityLabel(loc.t(.refreshProcessList))
            }
            .font(.system(size: 9))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 5)
            if store.processes.isEmpty {
                Text(loc.t(.processListUnavailable))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.dim)
                    .padding(.horizontal, 5)
            }
            ForEach(store.processes) { process in
                ProcessRow(process: process) { store.refreshProcesses() }
            }
        }
        .panel()
    }

    private func rate(_ bytes: Double?) -> String {
        guard let bytes else { return "—" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary))/s"
    }

    private func temperature(_ celsius: Double?) -> String {
        celsius.map { "\(Int($0.rounded()))°C" } ?? "—"
    }

}

private struct MetricCard<Content: View>: View {
    let title: String
    let accessory: String
    var symbol: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.blue)
                }
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                Spacer(minLength: 1)
                Text(accessory)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.mint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .panel()
    }
}

private struct BatteryRing: View {
    let symbol: String
    let name: String
    let percentage: Int?

    /// 环体直径。原来 49pt 会把整块电量区顶到上方的分隔线上，
    /// 收到 34pt 后与外设文字行、左侧 MacBook 百分比在视觉上齐平。
    private let diameter: CGFloat = 34
    private let lineWidth: CGFloat = 4
    @Environment(\.localization) private var loc

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: lineWidth)
                if let percentage {
                    Circle()
                        .trim(from: 0, to: CGFloat(percentage) / 100)
                        .stroke(Palette.mint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: diameter, height: diameter)
            Text("\(name) \(percentage.map { "\($0)%" } ?? loc.t(.notAvailable))")
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.t(.batteryPercentA11y,
                                    name,
                                    percentage.map { "\($0)%" } ?? loc.t(.unknown)))
    }
}

private struct ProcessRow: View {
    let process: ProcessReading
    let onAction: () -> Void
    @State private var hovering = false
    @Environment(\.localization) private var loc

    /// CPU 超过阈值时才用琥珀色提醒；其余连同进程名一起走暗色，整体压低亮度。
    private var cpuColor: Color { process.cpuPercent > 50 ? Palette.amber : Palette.dim }

    var body: some View {
        HStack(spacing: 5) {
            Text(process.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(hovering ? Palette.mint : Palette.dim)
            Spacer(minLength: 4)
            Text(ByteCountFormatter.string(fromByteCount: Int64(process.memoryBytes), countStyle: .memory))
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(Palette.dim)
            Text(String(format: "%.1f%%", process.cpuPercent))
                .frame(width: 48, alignment: .trailing)
                .foregroundStyle(cpuColor)
            Menu {
                Button(loc.t(.revealInFinder)) { ProcessActions.reveal(process) }
                Button(loc.t(.copyProcessName)) { ProcessActions.copy(process.name) }
                Button(loc.t(.copyPID)) { ProcessActions.copy("\(process.pid)") }
                Divider()
                // 用 ProcessInspector（libproc）判断可用性：NSRunningApplication 对
                // 非 GUI 进程恒为 nil，曾导致进程榜里绝大多数条目无法操作。
                Button(loc.t(.terminate)) { ProcessActions.terminate(process, force: false); onAction() }
                    .disabled(!ProcessActions.canTerminate(process))
                Button(loc.t(.forceQuit) + "…", role: .destructive) {
                    ProcessActions.terminate(process, force: true)
                    onAction()
                }
                .disabled(!ProcessActions.canTerminate(process))
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            // 悬停时才点亮操作入口；非悬停保持克制，避免整列图标抢视线。
            .foregroundStyle(hovering ? Palette.mint : Palette.dim)
            .opacity(hovering ? 1 : 0.7)
            .accessibilityLabel(loc.t(.processMenuLabel, process.name))
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        // 悬停高亮：整行铺满可命中区域，避免只有文字部分响应鼠标。
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? Palette.rowHover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .accessibilityElement(children: .contain)
    }
}

private extension View {
    func panel() -> some View {
        self.padding(9)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 设置页的分区。项目变多后单页 Form 会很长，改为左侧导航 + 右侧内容。
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, monitoring, update, language, about
    var id: String { rawValue }

    func title(_ loc: Localization) -> String {
        switch self {
        case .general: return loc.t(.settingsGeneral)
        case .monitoring: return loc.t(.settingsMonitoring)
        case .update: return loc.t(.settingsUpdate)
        case .language: return loc.t(.settingsLanguage)
        case .about: return loc.t(.settingsAbout)
        }
    }

    /// 导航项图标，便于快速定位。
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .monitoring: return "waveform.path.ecg"
        case .update: return "arrow.triangle.2.circlepath"
        case .language: return "globe"
        case .about: return "info.circle"
        }
    }
}

struct SettingsPanel: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var localization: Localization
    @State private var selection: SettingsSection = .general

    private var cacheDays: Int { Int(store.appCacheDays.rounded()) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: .infinity,
               minHeight: 380, idealHeight: 440, maxHeight: .infinity)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                SidebarRow(section: section,
                           isSelected: selection == section,
                           title: section.title(localization)) {
                    selection = section
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 168)
        .background(Palette.background.opacity(0.35))
    }

    /// 右侧内容随选中分区切换；每个分区各自是一个 grouped Form。
    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general: generalPage
        case .monitoring: monitoringPage
        case .update: updatePage
        case .language: languagePage
        case .about: aboutPage
        }
    }

    private var generalPage: some View {
        Form {
            Picker(localization.t(.menuBarAnimal), selection: $store.animal) {
                // 显示本地化名称，tag 仍然是持久化标识
                ForEach(Animal.allCases) { animal in
                    Text(animal.displayName).tag(animal)
                }
            }
            Toggle(localization.t(.pauseAnimation), isOn: $store.animationPaused)
            Text(localization.t(.pauseAnimationHint))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var monitoringPage: some View {
        Form {
            Section {
                Picker(localization.t(.refreshRate), selection: $store.refreshRate) {
                    ForEach(RefreshRate.allCases, id: \.self) { rate in
                        Text(rate.title).tag(rate)
                    }
                }
                Text(store.refreshRate.detail + localization.t(.refreshRateHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } footer: {
                Text(localization.t(.refreshRateFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(localization.t(.appCacheDays, cacheDays),
                        value: $store.appCacheDays, in: 1...365, step: 1)
                Text(localization.t(.appCacheHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var updatePage: some View {
        Form {
            UpdateSection(updates: updates)
        }
        .formStyle(.grouped)
    }

    private var languagePage: some View {
        Form {
            Picker(localization.t(.language), selection: Binding(
                get: { localization.language },
                set: { localization.set($0) }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.nativeName).tag(language)
                }
            }
            Text(localization.t(.languageHint))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(localization.t(.languageRestartHint))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var aboutPage: some View {
        Form {
            LabeledContent(localization.t(.aboutVersion), value: updates.currentVersionText)
            LabeledContent(localization.t(.aboutSystem), value: runtimeSystemText)
            LabeledContent(localization.t(.aboutCpu), value: store.chipName ?? localization.t(.unknown))
            LabeledContent(localization.t(.aboutUptime), value: uptimeText)
            Text(localization.t(.gpuTemperatureHint))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var runtimeSystemText: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion)"
    }

    private var uptimeText: String {
        guard let boot = store.machine.bootTime else { return localization.t(.notAvailable) }
        return UptimeText.duration(seconds: Date().timeIntervalSince(boot))
            ?? localization.t(.notAvailable)
    }
}

/// 左侧导航的一行。用自定义样式而不是 List(selection:)，
/// 是为了在浅色/深色下都能得到一致的圆角选中态。
private struct SidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(title).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor
                          : (hovering ? Color.primary.opacity(0.07) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}