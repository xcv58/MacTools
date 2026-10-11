import SwiftUI
import MacToolsPluginKit

struct TrackpadScaleView: View {
    let model: TrackpadScaleModel
    let localization: PluginLocalization
    @State private var knownGrams = ""

    private func localized(_ key: String, _ fallback: String) -> String {
        localization.string(key, defaultValue: fallback)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(localized("approximate", "估算重量 · 实验性"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    PluginMetricValue(
                        model.measurement.estimatedGrams.map { String(format: "≈ %.0f", locale: PluginRuntimeLocalization.locale, $0) } ?? "—",
                        unit: "g", isProminent: true
                    )
                    .accessibilityLabel(localized("approximate", "估算重量 · 实验性"))
                    .accessibilityValue(model.measurement.estimatedGrams.map { String(format: "≈ %.0f g", locale: PluginRuntimeLocalization.locale, $0) } ?? status)
                }
                Spacer()
                Label(model.measurement.isStable ? localized("stable", "稳定") : localized("unstable", "未稳定"),
                      systemImage: model.measurement.isStable ? "checkmark.circle" : "waveform")
                    .font(PluginSettingsTheme.Typography.statusBadge).foregroundStyle(.secondary)
            }
            Text(status).font(PluginSettingsTheme.Typography.rowTitle)
                .accessibilityIdentifier("trackpad-scale-status")
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Button(localized("start", "开始")) { model.start() }.disabled(model.isRunning)
                    .buttonStyle(.borderedProminent)
                Button(localized("stop", "停止")) { model.stop() }.disabled(!model.isRunning)
                    .buttonStyle(.bordered)
                Button(localized("tare", "归零")) { model.tare() }
                    .disabled(!model.isRunning || !model.measurement.canTare).buttonStyle(.bordered)
            }.controlSize(.small)
            Text(localized("instructions", "保持一根手指轻触触控板，等待读数稳定后归零，再轻放小物件。手指不要抬起或更换。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Label(localized("calibration", "已知重量校准"), systemImage: "slider.horizontal.3")
                .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
            Text(localized("calibration.instructions", "先在没有物件时归零，再放置已知重量的物件（1–100 g）。保持同一根手指轻触，稳定后保存。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                TextField(localized("knownWeight", "已知重量"), text: $knownGrams)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 80, idealWidth: 100, maxWidth: 140)
                    .accessibilityLabel(localized("knownWeight", "已知重量"))
                Text("g").font(PluginSettingsTheme.Typography.rowDescription)
                Button(localized("saveCalibration", "保存校准")) { model.calibrate(knownGrams) }
                    .disabled(!model.isRunning || !model.measurement.canCalibrate)
                Button(localized("resetCalibration", "重置校准")) { model.resetCalibration() }
                    .disabled(!model.isRunning)
            }.buttonStyle(.bordered).controlSize(.small)
            Text(!model.hasCalibration
                 ? localized("uncalibrated", "未校准：原始压力差仅作为经验估算。")
                 : localized("calibrated", "已校准：校准仍不能保证准确度。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            if model.isRunning, model.measurement.device?.hasPersistentIdentity == false {
                Text(localized("temporaryCalibration", "设备标识不可用，校准仅在本次会话有效。"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
            if model.calibrationError {
                Text(localized("calibrationError", "请输入 1–100 g 的有效重量，并等待有物件的读数稳定后重试。"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red)
            }
            Divider()
            Text(localized("safeUse", "仅轻放小物件，勿用尖锐或重物。不可用于关键测量。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            Text(localized("limitations", "仅支持内置 Force Touch 触控板。称重时暂停 MacTools 触控板手势；停止或关闭页面后恢复。依赖 macOS 私有 API，兼容性可能变化。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: String {
        let state = model.measurement.state
        switch state {
        case .stopped: return localized("state.stopped", "点按“开始”以称重。")
        case .unsupported: return localized("state.unsupported", "未检测到支持压力读取的内置 Force Touch 触控板。")
        case .noContact: return localized("state.noContact", "请保持一根手指轻触触控板。")
        case .multipleContacts: return localized("state.multipleContacts", "检测到多个触点。请只保留一根手指，然后重新归零。")
        case .needsTare: return localized("state.needsTare", "等待读数稳定，然后归零。")
        case .measuring: return localized("state.measuring", "保持手指位置和力度不变；读数仅供参考。")
        case .invalidSample: return localized("state.invalidSample", "压力读数无效。请重新轻触并归零。")
        case .interrupted: return localized("state.interrupted", "会话已中断。请重新开始并归零。")
        }
    }
}
