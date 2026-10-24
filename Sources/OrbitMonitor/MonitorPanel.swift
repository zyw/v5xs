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
}

struct MonitorPanel: View {
    @ObservedObject var store: MonitorStore
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
            processCard
            HStack {
                Button("设置", action: onOpenSettings)
                Spacer()
                Text("每秒更新").foregroundStyle(Palette.muted)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
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
                Text(store.healthScore.map(HealthScore.label(for:)) ?? "采集中")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                Spacer()
            }
            HStack(spacing: 5) {
                badge(store.chipName ?? "芯片未知")
                badge("\(store.machine.memoryBytes / 1_073_741_824) GB")
                let version = ProcessInfo.processInfo.operatingSystemVersion
                badge("macOS \(version.majorVersion).\(version.minorVersion)")
                let uptime = store.machine.bootTime.flatMap {
                    UptimeText.describe(seconds: Date().timeIntervalSince($0))
                } ?? "—"
                badge("已运行 \(uptime)")
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
                Text("软件卸载 ↗")
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
        .accessibilityHint("打开软件卸载窗口")
        .help("点按综合评分打开软件卸载；评分由系统热状态、CPU 使用率和内存占用估算，缺少数据时显示破折号")
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }

    private var cpuCard: some View {
        MetricCard(title: "CPU", accessory: cpuCoreText) {
            Text(store.cpu.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Chart(store.cpuHistory.suffix(60)) { point in
                LineMark(x: .value("时间", point.time), y: .value("占用", point.value))
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
            return "\(store.machine.cpuCores) 核 · \(performance)P + \(efficiency)E"
        }
        return "\(store.machine.cpuCores) 核"
    }

    private var gpuCard: some View {
        MetricCard(title: "GPU 活跃度", accessory: store.gpuCores.map { "\($0) 核" } ?? "核数未知") {
            Text(store.gpuUsage.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 25, weight: .bold, design: .rounded))
            if store.gpuUsage != nil {
                Chart(store.gpuHistory) { point in
                    LineMark(x: .value("时间", point.time), y: .value("占用", point.value))
                        .foregroundStyle(Palette.blue)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 21)
                .accessibilityLabel("GPU 活跃度历史曲线")
            } else {
                Text("当前设备未提供 GPU 活跃度")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 21, alignment: .bottomLeading)
                    .lineLimit(2)
            }
        }
    }

    private var memoryCard: some View {
        MetricCard(title: "内存", accessory: "") {
            Text(store.memoryUsed.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—")
                .font(.system(size: 19, weight: .bold, design: .rounded))
            ProgressView(value: min(Double(store.memoryUsed ?? 0) / Double(max(store.machine.memoryBytes, 1)), 1))
                .tint(Palette.mint)
                .controlSize(.mini)
            Text("总计 \(ByteCountFormatter.string(fromByteCount: Int64(store.machine.memoryBytes), countStyle: .memory))")
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
        }
    }

    private var diskCard: some View {
        MetricCard(title: "可用空间", accessory: store.diskTotal.map {
            "总计 \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))"
        } ?? "总计 —", symbol: "internaldrive") {
            Text(store.diskAvailable.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                .font(.system(size: 19, weight: .bold, design: .rounded))
            ProgressView(value: diskUsedFraction)
                .tint(Palette.blue)
                .controlSize(.mini)
                .accessibilityLabel("磁盘已用空间")
                .accessibilityValue("\(Int(diskUsedFraction * 100))%")
            Text("读 \(rate(store.diskRead)) · 写 \(rate(store.diskWrite))")
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
                Text("网络").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                badge(store.networkType)
            }
            Text(rate(store.download))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel("下载 \(rate(store.download))")
            if chartPoints.isEmpty {
                Text("等待网络采样…")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 30)
            } else {
                Chart {
                    ForEach(chartPoints) { point in
                        LineMark(x: .value("时间", point.time), y: .value("下载", point.download))
                            .foregroundStyle(Palette.mint)
                        LineMark(x: .value("时间", point.time), y: .value("上传", point.upload))
                            .foregroundStyle(Palette.blue)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 30)
                .accessibilityLabel("过去一分钟的网络下载与上传曲线")
            }
            HStack {
                Text("上传 \(rate(store.upload))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Button(store.lowLatencyMode ? "关闭低延迟" : "开启低延迟") {
                    store.lowLatencyMode.toggle()
                }
                .buttonStyle(.plain)
                .help("低延迟模式每 0.5 秒采样一次")
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
                Text("温度").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                badge(store.thermalDescription)
            }
            Text(temperature(store.cpuTemperature))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .accessibilityLabel("CPU 温度 \(temperature(store.cpuTemperature))")
            ProgressView(value: min(max((store.cpuTemperature ?? 0) / 110, 0), 1))
                .tint(Palette.mint)
                .controlSize(.mini)
                .frame(height: 30)
                .accessibilityLabel("CPU 温度比例")
                .accessibilityValue(temperature(store.cpuTemperature))
            Text("GPU \(temperature(store.gpuTemperature)) · \(store.chipName ?? "—")")
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 98, alignment: .topLeading)
        .panel()
    }

    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("电量").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                Text("本机与已连接外设")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.muted)
            }
            Divider().overlay(.white.opacity(0.1))
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacBook").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Text(store.batteryPercentage.map { "\($0)%" } ?? "—")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(store.batteryStatus).font(.system(size: 9)).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider().frame(height: 48)
                BatteryRing(symbol: "magicmouse.fill", name: "鼠标", percentage: peripheral(kind: .mouse)?.percentage)
                BatteryRing(symbol: "keyboard.fill", name: "键盘", percentage: peripheral(kind: .keyboard)?.percentage)
            }
        }
        .panel()
    }

    private func peripheral(kind: PeripheralBattery.Kind) -> PeripheralBattery? {
        store.peripherals.first { $0.kind == kind }
    }

    private var processCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("高占用进程").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("内存").frame(width: 70, alignment: .trailing)
                Text("CPU").frame(width: 48, alignment: .trailing)
                Button { store.refreshProcesses() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.mint)
                    .frame(width: 22)
                    .accessibilityLabel("刷新进程列表")
            }
            .font(.system(size: 9))
            .foregroundStyle(Palette.muted)
            if store.processes.isEmpty {
                Text("当前无法读取进程列表").font(.system(size: 10)).foregroundStyle(Palette.muted)
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

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 5)
                if let percentage {
                    Circle()
                        .trim(from: 0, to: CGFloat(percentage) / 100)
                        .stroke(Palette.mint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 49, height: 49)
            Text("\(name) \(percentage.map { "\($0)%" } ?? "—")")
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name)电量\(percentage.map { "\($0)%" } ?? "未知")")
    }
}

private struct ProcessRow: View {
    let process: ProcessReading
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(process.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(ByteCountFormatter.string(fromByteCount: Int64(process.memoryBytes), countStyle: .memory))
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(Palette.muted)
            Text(String(format: "%.1f%%", process.cpuPercent))
                .frame(width: 48, alignment: .trailing)
                .foregroundStyle(process.cpuPercent > 50 ? Palette.amber : Palette.muted)
            Menu {
                Button("在访达中显示") { ProcessActions.reveal(process) }
                    .disabled(NSRunningApplication(processIdentifier: process.pid)?.bundleURL == nil)
                Button("复制进程名称") { ProcessActions.copy(process.name) }
                Button("复制 PID") { ProcessActions.copy("\(process.pid)") }
                Divider()
                Button("终止") { ProcessActions.terminate(process, force: false); onAction() }
                Button("强制退出…", role: .destructive) {
                    ProcessActions.terminate(process, force: true)
                    onAction()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .accessibilityLabel("\(process.name)操作")
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.vertical, 1)
    }
}

private extension View {
    func panel() -> some View {
        self.padding(9)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsPanel: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        Form {
            Picker("菜单栏动物", selection: $store.animal) {
                ForEach(Animal.allCases) { animal in
                    Text(animal.rawValue).tag(animal)
                }
            }
            Toggle("暂停动画", isOn: $store.animationPaused)
            Text("减少动态效果开启时，图标会保持静态。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("GPU 活跃度按设备支持情况显示；CPU／GPU 温度仅在已验证的 Mac14,2 上读取。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 370, height: 250)
    }
}
