// MicLab — macOS 麦克风实时监听台（极客风 GUI）
//
// 设计要点（均为本机实测结论）：
// 1. AVAudioEngine 的 inputNode / outputNode 无法用 kAudioOutputUnitProperty_CurrentDevice 绑定设备，
//    设置返回成功但实际不生效。因此切换设备时必须临时修改“系统默认输入/输出设备”，
//    在给出的设备上重建引擎；停止/退出时恢复原设备。
// 2. 引擎内部图采样率跟随输出设备（例如耳机 96k），输入 48k 会被重采样。
//    超低延迟模式会把输出设备采样率对齐到输入设备（48k），并压到 64 帧缓冲。
// 3. 底噪处理：高通 + DynamicsProcessor 的扩展器（噪声门）+ 可选高频架衰减。

import SwiftUI
import AVFoundation
import AudioToolbox
import CoreAudio
import Accelerate

// MARK: - CoreAudio 工具

enum CoreAudioUtil {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func name(_ id: AudioDeviceID) -> String {
        var a = address(kAudioDevicePropertyDeviceNameCFString)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, ptr)
        }
        return status == noErr ? (value as String) : "未知设备"
    }

    static func channelCount(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                  alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func sampleRate(_ id: AudioDeviceID) -> Double {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &rate)
        return rate
    }

    static func availableSampleRates(_ id: AudioDeviceID) -> [Double] {
        var a = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.map { $0.mMinimum }
    }

    @discardableResult
    static func setSampleRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Double>.size), &value) == noErr
    }

    static func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID? {
        var a = address(sel)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultDevice(_ sel: AudioObjectPropertySelector, _ id: AudioDeviceID) -> Bool {
        var a = address(sel)
        var value = id
        return AudioObjectSetPropertyData(system, &a, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    static func bufferFrames(_ id: AudioDeviceID) -> UInt32 {
        var a = address(kAudioDevicePropertyBufferFrameSize)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &frames)
        return frames
    }

    @discardableResult
    static func setBufferFrames(_ id: AudioDeviceID, _ frames: UInt32) -> UInt32 {
        var a = address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        return bufferFrames(id)
    }

    static func inputVolume(_ id: AudioDeviceID) -> Float? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                           mScope: kAudioDevicePropertyScopeInput,
                                           mElement: kAudioObjectPropertyElementMain)
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

// MARK: - 基础模型

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double

    var isSpeaker: Bool {
        let n = name.lowercased()
        return name.contains("扬声器") || n.contains("speaker") || name.contains("内置")
    }

    var summary: String {
        "\(Int(sampleRate)) Hz · 入\(inputChannels)/出\(outputChannels)"
    }
}

enum Preset: Int, CaseIterable, Identifiable {
    case off, light, strong
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: return "关"
        case .light: return "轻"
        case .strong: return "强"
        }
    }
    var helpText: String {
        switch self {
        case .off: return "关：只做直通 + 总增益，不启用均衡、压缩、降噪"
        case .light: return "轻：日常人声增强（低频切除 + 存在感 + 轻度压缩），适合安静房间"
        case .strong: return "强：更明显的存在感与压缩，适合嘈杂环境或说话音量偏小"
        }
    }
}

struct LogLine: Identifiable {
    enum Kind { case info, good, warn, error }
    let id = UUID()
    let time: Date
    let text: String
    let kind: Kind
}

struct ChainSpec {
    var preset: Preset = .light
    var hpf: Double = 100
    var gateEnabled: Bool = true
    var gateLevel: Double = -48
    var denoise: Bool = true
    var makeup: Double = 2
    var ultra: Bool = false
    var inputID: AudioDeviceID = 0
    var outputID: AudioDeviceID = 0
}

// MARK: - 电平采集（音频线程 → 主线程）

final class LevelProbe {
    private let lock = NSLock()
    private var rms: Float = -90
    private var peak: Float = -90
    private var held: Float = -90
    private var holdUntil: TimeInterval = 0
    private var clipFlag = false
    private var callbacks = 0
    // 底噪自检累加
    private var sumSquares = 0.0
    private var sampleCount = 0.0
    private var autoSum = false

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = vDSP_Length(buffer.frameLength)
        guard n > 0 else { return }
        var rmsValue: Float = 0
        var maxValue: Float = 0
        vDSP_rmsqv(data[0], 1, &rmsValue, n)
        vDSP_maxmgv(data[0], 1, &maxValue, n)
        let rmsDB = 20 * log10(max(rmsValue, 1e-7))
        let peakDB = 20 * log10(max(maxValue, 1e-7))

        lock.lock()
        callbacks += 1
        if rmsDB > rms { rms += (rmsDB - rms) * 0.5 } else { rms += (rmsDB - rms) * 0.08 }
        if peakDB > peak { peak = peakDB } else { peak += (peakDB - peak) * 0.12 }
        if peakDB > held {
            held = peakDB
            holdUntil = CACurrentMediaTime() + 0.7
        } else if CACurrentMediaTime() > holdUntil {
            held += (-90 - held) * 0.05
        }
        if peakDB > -0.5 { clipFlag = true }
        if autoSum {
            sumSquares += Double(rmsValue * rmsValue) * Double(buffer.frameLength)
            sampleCount += Double(buffer.frameLength)
        }
        lock.unlock()
    }

    func snapshot() -> (rms: Float, peak: Float, held: Float, clipped: Bool) {
        lock.lock(); defer { lock.unlock() }
        let value = (rms, peak, held, clipFlag)
        clipFlag = false
        return value
    }

    func beginNoiseMeasure() {
        lock.lock(); sumSquares = 0; sampleCount = 0; autoSum = true; lock.unlock()
    }

    func endNoiseMeasure() -> Double {
        lock.lock(); defer { lock.unlock() }
        autoSum = false
        guard sampleCount > 0, sumSquares > 0 else { return -120 }
        return 10 * log10(sumSquares / sampleCount)
    }

    func reset() {
        lock.lock()
        rms = -90; peak = -90; held = -90; clipFlag = false
        sumSquares = 0; sampleCount = 0; autoSum = false
        lock.unlock()
    }

    func callbackCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return callbacks
    }
}

// MARK: - 引擎

struct EngineKit {
    let engine: AVAudioEngine
    let eq: AVAudioUnitEQ
    let dyn: AVAudioUnitEffect
    let probe: LevelProbe
    let graphRate: Double
    let inputFrames: UInt32
    let outputFrames: UInt32
    let latencyMs: Double
}

enum EngineError: LocalizedError {
    case noInputFormat
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputFormat: return "输入设备没有可用的音频格式，请检查麦克风是否连接/开机"
        case .startFailed(let message): return "音频引擎启动失败：\(message)"
        }
    }
}

enum AudioGraph {
    static let dynThreshold: AudioUnitParameterID = 0
    static let dynHeadRoom: AudioUnitParameterID = 1
    static let dynExpansionRatio: AudioUnitParameterID = 2
    static let dynExpansionThreshold: AudioUnitParameterID = 3
    static let dynAttack: AudioUnitParameterID = 4
    static let dynRelease: AudioUnitParameterID = 5
    static let dynOverallGain: AudioUnitParameterID = 6

    static func setParameter(_ unit: AudioUnit, _ id: AudioUnitParameterID, _ value: Float) {
        AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0)
    }

    /// 轮询等待设备采样率真正切换完成（改采样率是异步操作）
    static func waitForSampleRate(_ id: AudioDeviceID, _ target: Double, timeout: Double = 1.5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if abs(CoreAudioUtil.sampleRate(id) - target) < 1 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// 按档位/开关设置整条处理链
    static func apply(_ spec: ChainSpec, eq: AVAudioUnitEQ, dyn: AVAudioUnitEffect) {
        let off = spec.preset == .off
        eq.bypass = false                      // 保持 EQ 生效，以便“总增益”在关档也能用
        eq.globalGain = Float(spec.makeup)

        // 0：高通（去低频嗡声/风噪）
        let hp = eq.bands[0]
        hp.filterType = .highPass
        hp.frequency = Float(spec.hpf)
        hp.bandwidth = 0.7
        hp.bypass = off || spec.hpf < 25

        // 1：人声存在感
        let presence = eq.bands[1]
        presence.filterType = .parametric
        presence.frequency = 2600
        presence.bandwidth = 1.0
        presence.gain = spec.preset == .strong ? 4.0 : 2.0
        presence.bypass = off

        // 2：高频“空气感”
        let air = eq.bands[2]
        air.filterType = .highShelf
        air.frequency = 6500
        air.bandwidth = 1.0
        air.gain = (spec.preset == .strong ? 3.0 : 1.5) * (spec.denoise ? 0.4 : 1.0)
        air.bypass = off

        // 3：降噪（高频架衰减，压“嘶嘶”声）
        let denoise = eq.bands[3]
        denoise.filterType = .highShelf
        denoise.frequency = 5000
        denoise.bandwidth = 1.0
        denoise.gain = -6.0
        denoise.bypass = off || !spec.denoise

        // 压缩 + 噪声门（扩展器），二者都由 DynamicsProcessor 完成，零额外延迟
        dyn.bypass = off
        guard !off else { return }
        let unit = dyn.audioUnit
        let strong = spec.preset == .strong
        setParameter(unit, dynThreshold, strong ? -24 : -18)
        setParameter(unit, dynHeadRoom, strong ? 6 : 10)
        setParameter(unit, dynAttack, strong ? 0.005 : 0.01)
        setParameter(unit, dynRelease, strong ? 0.12 : 0.15)
        setParameter(unit, dynOverallGain, strong ? 5 : 2)
        setParameter(unit, dynExpansionThreshold, Float(spec.gateLevel))
        setParameter(unit, dynExpansionRatio, spec.gateEnabled ? 12 : 1)
    }

    /// 在后台线程构建引擎（会临时切换系统默认输入/输出设备）
    static func build(spec: ChainSpec) throws -> EngineKit {
        // 1) 切默认设备（引擎节点只跟随系统默认设备）
        CoreAudioUtil.setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, spec.inputID)
        CoreAudioUtil.setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, spec.outputID)
        Thread.sleep(forTimeInterval: 0.3)

        // 2) 超低延迟：把输出采样率对齐到输入设备，避免重采样
        //    设备改采样率是异步的，必须等回读值真正变化后再建引擎，
        //    否则引擎会先按旧采样率建图，随后被设备重置停掉。
        if spec.ultra {
            let inputRate = CoreAudioUtil.sampleRate(spec.inputID)
            let available = CoreAudioUtil.availableSampleRates(spec.outputID)
            if available.contains(where: { abs($0 - inputRate) < 1 }) {
                CoreAudioUtil.setSampleRate(spec.outputID, inputRate)
                waitForSampleRate(spec.outputID, inputRate)
            }
            Thread.sleep(forTimeInterval: 0.15)
        }

        // 3) 缓冲帧数：超低延迟 64，否则 256
        let target: UInt32 = spec.ultra ? 64 : 256
        let inputFrames = CoreAudioUtil.setBufferFrames(spec.inputID, target)
        let outputFrames = CoreAudioUtil.setBufferFrames(spec.outputID, target)

        // 4) 建图
        let engine = AVAudioEngine()
        let eq = AVAudioUnitEQ(numberOfBands: 4)
        let dyn = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0))
        engine.attach(eq)
        engine.attach(dyn)

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw EngineError.noInputFormat }

        apply(spec, eq: eq, dyn: dyn)

        engine.connect(engine.inputNode, to: eq, format: format)
        engine.connect(eq, to: dyn, format: format)
        engine.connect(dyn, to: engine.mainMixerNode, format: format)
        engine.prepare()

        do {
            try engine.start()
        } catch {
            throw EngineError.startFailed(error.localizedDescription)
        }

        // 5) 电平表（在主混音器输出上取样，不影响音频链路）
        let probe = LevelProbe()
        let tapFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, _ in
            probe.process(buffer)
        }

        let graphRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let presentation = Double(engine.inputNode.presentationLatency + engine.outputNode.presentationLatency) * 1000
        let bufferMs = (Double(inputFrames) + Double(outputFrames)) / max(graphRate, 1) * 1000
        let latency = bufferMs + presentation

        return EngineKit(engine: engine, eq: eq, dyn: dyn, probe: probe,
                         graphRate: graphRate, inputFrames: inputFrames,
                         outputFrames: outputFrames, latencyMs: latency)
    }
}

// MARK: - 状态模型

@MainActor
final class MonitorModel: ObservableObject {
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputID: AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?

    @Published var preset: Preset = .light
    @Published var denoise = true
    @Published var gateEnabled = true
    @Published var ultra = false
    @Published var hpf: Double = 100
    @Published var gateLevel: Double = -48
    @Published var makeup: Double = 2

    @Published var running = false
    @Published var busy = false
    @Published var statusText = "待机"
    @Published var meterRMS: Float = -90
    @Published var meterPeak: Float = -90
    @Published var meterHeld: Float = -90
    @Published var clipped = false
    @Published var history: [Float] = Array(repeating: -90, count: 72)

    @Published var statLines: [(String, String)] = []
    @Published var logLines: [LogLine] = []
    @Published var showSpeakerAlert = false
    @Published var noiseReport: String = ""
    @Published var measuringNoise = false

    private var kit: EngineKit?
    private var ticker: Timer?
    private var scanTimer: Timer?
    private var pendingOutputID: AudioDeviceID?
    private var originalInput: AudioDeviceID?
    private var originalOutput: AudioDeviceID?
    private var originalOutputRate: Double?

    // MARK: 启动

    func bootstrap() {
        refreshDevices(announce: false)
        autoSelect()
        updateStats()
        log("iTraeMicLab 已启动，等待指令", .good)
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pullMeter() }
        }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices(announce: true) }
        }
    }

    func shutdown() {
        ticker?.invalidate()
        scanTimer?.invalidate()
        stop(reason: "程序退出", quiet: true)
    }

    // MARK: 设备枚举

    private func makeDevices() -> [AudioDevice] {
        CoreAudioUtil.deviceIDs().compactMap { id in
            let ins = CoreAudioUtil.channelCount(id, kAudioObjectPropertyScopeInput)
            let outs = CoreAudioUtil.channelCount(id, kAudioObjectPropertyScopeOutput)
            guard ins > 0 || outs > 0 else { return nil }
            return AudioDevice(id: id, name: CoreAudioUtil.name(id),
                               inputChannels: ins, outputChannels: outs,
                               sampleRate: CoreAudioUtil.sampleRate(id))
        }
    }

    private func refreshDevices(announce: Bool) {
        let all = makeDevices()
        let inputs = all.filter { $0.inputChannels > 0 }
        let outputs = all.filter { $0.outputChannels > 0 }
        let changed = inputs.map(\.id) != inputDevices.map(\.id) || outputs.map(\.id) != outputDevices.map(\.id)
        inputDevices = inputs
        outputDevices = outputs

        if let selectedInputID, !inputs.contains(where: { $0.id == selectedInputID }) {
            log("输入设备已断开，请重新选择", .warn)
            self.selectedInputID = nil
            if running { stop(reason: "输入设备断开") }
            autoSelect()
        }
        if let selectedOutputID, !outputs.contains(where: { $0.id == selectedOutputID }) {
            log("监听输出已断开，请重新选择", .warn)
            self.selectedOutputID = nil
            if running { stop(reason: "输出设备断开") }
            autoSelect()
        }
        if announce && changed { log("设备列表已刷新（\(inputs.count) 个输入 / \(outputs.count) 个输出）", .info) }
    }

    /// 默认：输入优先外接（名字含 USB）的设备，输出优先非扬声器设备
    private func autoSelect() {
        if selectedInputID == nil {
            selectedInputID = inputDevices.first(where: { $0.name.uppercased().contains("USB") })?.id
                ?? inputDevices.first?.id
        }
        if selectedOutputID == nil {
            selectedOutputID = outputDevices.first(where: { !$0.isSpeaker })?.id
                ?? outputDevices.first?.id
        }
    }

    // MARK: 选择变更

    func chooseInput(_ id: AudioDeviceID) {
        guard id != selectedInputID else { return }
        selectedInputID = id
        if let device = inputDevices.first(where: { $0.id == id }) {
            log("输入 → \(device.name)", .info)
        }
        if running { restart(reason: "输入设备切换") }
    }

    func chooseOutput(_ id: AudioDeviceID) {
        guard id != selectedOutputID else { return }
        if let device = outputDevices.first(where: { $0.id == id }), device.isSpeaker {
            pendingOutputID = id
            showSpeakerAlert = true
            return
        }
        applyOutput(id)
    }

    func confirmSpeakerSelection() {
        if let id = pendingOutputID { applyOutput(id) }
        pendingOutputID = nil
    }

    func cancelSpeakerSelection() {
        pendingOutputID = nil
        log("已取消选择扬声器", .info)
    }

    private func applyOutput(_ id: AudioDeviceID) {
        selectedOutputID = id
        if let device = outputDevices.first(where: { $0.id == id }) {
            log("监听输出 → \(device.name)", .info)
        }
        if running { restart(reason: "监听输出切换") }
    }

    // MARK: 运行控制

    func toggleRun() {
        if running { stop(reason: "手动停止") } else { start() }
    }

    func start() {
        guard !busy else { return }
        guard let inputID = selectedInputID, let outputID = selectedOutputID else {
            log("!! 请先选择输入和监听输出设备", .error)
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            launch(inputID: inputID, outputID: outputID)
        case .notDetermined:
            busy = true
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.busy = false
                    if granted {
                        self.launch(inputID: inputID, outputID: outputID)
                    } else {
                        self.log("!! 麦克风权限被拒绝：系统设置 → 隐私与安全性 → 麦克风，勾选 iTraeMicLab 后重试", .error)
                    }
                }
            }
        default:
            log("!! 麦克风权限未开启：系统设置 → 隐私与安全性 → 麦克风，勾选 iTraeMicLab", .error)
        }
    }

    private func launch(inputID: AudioDeviceID, outputID: AudioDeviceID) {
        busy = true
        statusText = "启动中…"
        stopEngineOnly()
        lastCallbackCount = 0
        lastCallbackChange = Date()
        warnedNoData = false

        originalInput = CoreAudioUtil.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        originalOutput = CoreAudioUtil.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        originalOutputRate = CoreAudioUtil.sampleRate(outputID)

        let inputName = inputDevices.first(where: { $0.id == inputID })?.name ?? "?"
        let outputName = outputDevices.first(where: { $0.id == outputID })?.name ?? "?"
        log("启动中：\(inputName) → \(outputName)\(ultra ? "（超低延迟）" : "")", .info)

        let spec = makeSpec(inputID: inputID, outputID: outputID)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AudioGraph.build(spec: spec) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let kit):
                    self.kit = kit
                    self.running = true
                    self.statusText = "监听中"
                    self.updateStats()
                    self.log(String(format: "引擎已运行：图速率 %.0f Hz，延迟约 %.0f ms", kit.graphRate, kit.latencyMs), .good)
                    if kit.inputFrames != (spec.ultra ? 64 : 256) || kit.outputFrames != (spec.ultra ? 64 : 256) {
                        self.log("设备不支持目标缓冲，实际 入\(kit.inputFrames)/出\(kit.outputFrames) 帧", .warn)
                    }
                case .failure(let error):
                    self.running = false
                    self.statusText = "启动失败"
                    self.log("!! \(error.localizedDescription)", .error)
                    self.restoreDefaults()
                }
            }
        }
    }

    private func restart(reason: String) {
        log("重建链路：\(reason)", .info)
        let wasRunning = running
        stop(reason: reason, quiet: true)
        if wasRunning { start() }
    }

    func stop(reason: String = "停止", quiet: Bool = false) {
        stopEngineOnly()
        restoreDefaults()
        running = false
        statusText = "待机"
        meterRMS = -90; meterPeak = -90; meterHeld = -90
        updateStats()
        if !quiet { log("已停止（\(reason)），系统默认输入/输出已恢复", .warn) }
    }

    private func stopEngineOnly() {
        if let kit {
            kit.engine.mainMixerNode.removeTap(onBus: 0)
            kit.engine.stop()
            kit.probe.reset()
        }
        kit = nil
    }

    private func restoreDefaults() {
        if let originalInput { CoreAudioUtil.setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, originalInput) }
        if let originalOutput {
            if let rate = originalOutputRate {
                CoreAudioUtil.setSampleRate(originalOutput, rate)
            }
            CoreAudioUtil.setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, originalOutput)
        }
        originalInput = nil
        originalOutput = nil
        originalOutputRate = nil
    }

    // MARK: 参数

    private func makeSpec(inputID: AudioDeviceID, outputID: AudioDeviceID) -> ChainSpec {
        ChainSpec(preset: preset, hpf: hpf, gateEnabled: gateEnabled, gateLevel: gateLevel,
                  denoise: denoise, makeup: makeup, ultra: ultra,
                  inputID: inputID, outputID: outputID)
    }

    func applySettings() {
        guard let kit, running else { updateStats(); return }
        if let inputID = selectedInputID, let outputID = selectedOutputID {
            AudioGraph.apply(makeSpec(inputID: inputID, outputID: outputID), eq: kit.eq, dyn: kit.dyn)
        }
        updateStats()
    }

    func setUltra(_ value: Bool) {
        guard ultra != value else { return }
        ultra = value
        if running {
            restart(reason: value ? "开超低延迟" : "关超低延迟")
        } else {
            updateStats()
        }
    }

    // MARK: 电平刷新

    private var lastCallbackCount = 0
    private var lastCallbackChange = Date()
    private var warnedNoData = false

    private func pullMeter() {
        guard let kit else { return }
        if running && !kit.engine.isRunning {
            log("!! 音频引擎被系统停止（设备配置可能被重置），监听已终止", .error)
            stop(reason: "引擎意外停止")
            return
        }
        let count = kit.probe.callbackCount()
        if count != lastCallbackCount {
            lastCallbackCount = count
            lastCallbackChange = Date()
            warnedNoData = false
        } else if running && Date().timeIntervalSince(lastCallbackChange) > 2.0 && !warnedNoData {
            warnedNoData = true
            log("!! 2 秒内没有收到音频数据：请确认麦克风已连接、未静音且处于工作状态", .warn)
        }
        let value = kit.probe.snapshot()
        meterRMS = value.rms
        meterPeak = value.peak
        meterHeld = value.held
        if value.clipped { clipped = true }
        history.append(value.held)
        if history.count > 72 { history.removeFirst(history.count - 72) }
    }

    // MARK: 底噪自检

    func measureNoiseFloor() {
        guard let kit, running else {
            log("!! 需要先启动监听才能做底噪自检", .error)
            return
        }
        guard !measuringNoise else { return }
        measuringNoise = true
        noiseReport = ""
        kit.probe.beginNoiseMeasure()
        log("底噪自检开始：请保持安静 2 秒…", .info)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let db = kit.probe.endNoiseMeasure()
            self.measuringNoise = false
            let value = String(format: "%.1f dBFS", db)
            self.noiseReport = "底噪 RMS \(value)"
            self.log("底噪 RMS = \(value)", db > -50 ? .warn : .good)
            if db > -50 {
                self.log("提示：底噪偏大。可尝试：开降噪/噪声门、启用超低延迟、更换 USB 端口或缩短线材", .warn)
            } else if db > -65 {
                self.log("提示：底噪处于常见范围，开噪声门可进一步改善安静时的听感", .info)
            } else {
                self.log("底噪水平良好", .good)
            }
        }
    }

    // MARK: 状态面板

    private func updateStats() {
        var lines: [(String, String)] = []
        let inputName = inputDevices.first(where: { $0.id == selectedInputID })?.name ?? "未选择"
        let outputName = outputDevices.first(where: { $0.id == selectedOutputID })?.name ?? "未选择"
        lines.append(("输入设备", inputName))
        lines.append(("监听输出", outputName))
        if let kit, running {
            lines.append(("图采样率", String(format: "%.0f Hz", kit.graphRate)))
            lines.append(("缓冲帧", "入 \(kit.inputFrames) / 出 \(kit.outputFrames)"))
            lines.append(("估算延迟", String(format: "%.0f ms", kit.latencyMs)))
        } else {
            lines.append(("图采样率", "—"))
            lines.append(("缓冲帧", ultra ? "64 ×2" : "256 ×2"))
            lines.append(("估算延迟", "—"))
        }
        lines.append(("处理链", chainDescription))
        lines.append(("系统默认输入", CoreAudioUtil.defaultDevice(kAudioHardwarePropertyDefaultInputDevice).map { CoreAudioUtil.name($0) } ?? "—"))
        lines.append(("系统默认输出", CoreAudioUtil.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).map { CoreAudioUtil.name($0) } ?? "—"))
        statLines = lines
    }

    var chainDescription: String {
        if preset == .off { return "直通 + 增益 \(Int(makeup)) dB" }
        var parts = ["HPF \(Int(hpf))Hz", preset == .strong ? "存在+4dB" : "存在+2dB"]
        if denoise { parts.append("降噪-6dB") }
        if gateEnabled { parts.append("门限 \(Int(gateLevel))dB") }
        parts.append("压缩\(preset == .strong ? "强" : "轻")")
        parts.append("增益 \(Int(makeup))dB")
        return parts.joined(separator: " · ")
    }

    // MARK: 日志

    func log(_ text: String, _ kind: LogLine.Kind) {
        logLines.append(LogLine(time: Date(), text: text, kind: kind))
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }
}

// MARK: - 视觉主题

enum Theme {
    static let bg = Color(red: 0.016, green: 0.027, blue: 0.031)
    static let panel = Color(red: 0.043, green: 0.063, blue: 0.067)
    static let panelHi = Color(red: 0.063, green: 0.094, blue: 0.098)
    static let neon = Color(red: 0.0, green: 1.0, blue: 0.68)
    static let neonSoft = Color(red: 0.0, green: 0.55, blue: 0.40)
    static let grid = Color(red: 0.0, green: 0.45, blue: 0.35)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.16)
    static let danger = Color(red: 1.0, green: 0.29, blue: 0.36)
    static let text = Color(red: 0.78, green: 0.92, blue: 0.88)
    static let sub = Color(red: 0.38, green: 0.55, blue: 0.53)
}

func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

// MARK: - 通用组件

struct GeekPanel<Content: View>: View {
    let title: String
    var accent: Color = Theme.neon
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Rectangle().fill(accent).frame(width: 3, height: 11)
                Text(title.uppercased())
                    .font(mono(10, weight: .bold))
                    .foregroundColor(accent)
                    .tracking(1.8)
                Spacer()
            }
            content()
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(
            Rectangle().stroke(Theme.neonSoft.opacity(0.55), lineWidth: 1)
        )
    }
}

struct GeekButton: View {
    let title: String
    var color: Color = Theme.neon
    var filled: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(mono(12, weight: .bold))
                .tracking(1.2)
                .foregroundColor(filled ? Theme.bg : color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(filled ? color : Color.clear)
                .overlay(Rectangle().stroke(color, lineWidth: 1))
                .shadow(color: color.opacity(hovering ? 0.55 : 0.22), radius: hovering ? 8 : 3)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ReadoutRow: View {
    let key: String
    let value: String
    var valueColor: Color = Theme.text

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(mono(11))
                .foregroundColor(Theme.sub)
            Spacer(minLength: 8)
            Text(value)
                .font(mono(11, weight: .semibold))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct GeekSlider: View {
    let label: String
    let unit: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(mono(10)).foregroundColor(Theme.sub)
                Spacer()
                Text("\(Int(value)) \(unit)").font(mono(10, weight: .semibold)).foregroundColor(Theme.neon)
            }
            Slider(value: $value, in: range)
                .tint(Theme.neon)
                .controlSize(.mini)
        }
    }
}

struct GeekToggle: View {
    let label: String
    let hint: String
    @Binding var on: Bool
    var accent: Color = Theme.neon

    var body: some View {
        Button {
            on.toggle()
        } label: {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(on ? accent : Theme.panelHi)
                    .frame(width: 26, height: 12)
                    .overlay(Rectangle().stroke(on ? accent : Theme.sub.opacity(0.6), lineWidth: 1))
                    .overlay(
                        Rectangle()
                            .fill(on ? Theme.bg : Theme.sub)
                            .frame(width: 8, height: 8)
                            .offset(x: on ? 7 : -7)
                    )
                    .animation(.easeOut(duration: 0.15), value: on)
                Text(label).font(mono(11, weight: .medium)).foregroundColor(on ? Theme.text : Theme.sub)
                Spacer()
                Text(hint).font(mono(9)).foregroundColor(Theme.sub.opacity(0.8))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PresetSelector: View {
    @Binding var preset: Preset

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Preset.allCases) { item in
                Button {
                    preset = item
                } label: {
                    Text(item.label)
                        .font(mono(12, weight: .bold))
                        .foregroundColor(preset == item ? Theme.bg : Theme.sub)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(preset == item ? Theme.neon : Color.clear)
                        .overlay(
                            Rectangle().stroke(preset == item ? Theme.neon : Theme.neonSoft.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(item.helpText)
            }
        }
    }
}

// MARK: - LED 电平表

struct LedMeter: View {
    let value: Float       // 平滑 RMS，dBFS
    let held: Float        // 峰值保持
    let peak: Float

    private let segments = 44
    private let minDB: Float = -60

    private func fraction(_ db: Float) -> Double {
        let clamped = max(min(db, 0), minDB)
        return Double((clamped - minDB) / (0 - minDB))
    }

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 2
            let segWidth = (size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            let level = fraction(value)
            let holdLevel = fraction(held)
            for index in 0..<segments {
                let x = CGFloat(index) * (segWidth + gap)
                let ratio = Double(index + 1) / Double(segments)
                let db = Float(ratio) * (0 - minDB) + minDB
                let lit = ratio <= level
                let color: Color
                if db > -3 { color = Theme.danger }
                else if db > -12 { color = Theme.amber }
                else { color = Theme.neon }

                let rect = CGRect(x: x, y: 0, width: segWidth, height: size.height)
                context.fill(Path(rect), with: .color(lit ? color.opacity(0.95) : color.opacity(0.09)))
            }
            if held > minDB {
                let x = CGFloat(holdLevel) * size.width
                context.fill(Path(CGRect(x: max(0, x - 1.5), y: 0, width: 3, height: size.height)),
                             with: .color(Theme.text.opacity(0.9)))
            }
            if peak > -1.0 {
                context.fill(Path(CGRect(x: size.width - 4, y: 0, width: 4, height: size.height)),
                             with: .color(Theme.danger))
            }
        }
        .frame(height: 18)
        .overlay(Rectangle().stroke(Theme.neonSoft.opacity(0.4), lineWidth: 1))
    }
}

struct HistoryStrip: View {
    let history: [Float]

    var body: some View {
        Canvas { context, size in
            guard history.count > 1 else { return }
            let step = size.width / CGFloat(max(history.count - 1, 1))
            for index in 0..<history.count {
                let db = max(history[index], -60)
                let h = CGFloat((db + 60) / 60) * size.height
                let x = CGFloat(index) * step
                let color = db > -12 ? Theme.amber : (db > -3 ? Theme.danger : Theme.neon.opacity(0.8))
                context.fill(Path(CGRect(x: x, y: size.height - h, width: max(step * 0.85, 1), height: h)),
                             with: .color(color.opacity(0.7)))
            }
        }
        .frame(height: 64)
        .background(Theme.bg.opacity(0.6))
        .overlay(Rectangle().stroke(Theme.neonSoft.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - 背景

struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 26
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                path.addLines([CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height)])
                x += step
            }
            var y: CGFloat = 0
            while y < size.height {
                path.addLines([CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)])
                y += step
            }
            context.stroke(path, with: .color(Theme.grid.opacity(0.07)), lineWidth: 0.5)

            var scan = Path()
            var sy: CGFloat = 0
            while sy < size.height {
                scan.addLines([CGPoint(x: 0, y: sy), CGPoint(x: size.width, y: sy)])
                sy += 3
            }
            context.stroke(scan, with: .color(.black.opacity(0.12)), lineWidth: 0.5)
        }
        .background(
            RadialGradient(colors: [Color(red: 0.05, green: 0.10, blue: 0.10), Theme.bg],
                           center: .center, startRadius: 20, endRadius: 700)
        )
        .ignoresSafeArea()
    }
}

// MARK: - 版本信息

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var rawBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
    }
    /// 把 yyyyMMddHHmm 形式的构建号显示成易读时间
    static var build: String {
        let raw = rawBuild
        guard raw.count == 12,
              let y = Int(raw.prefix(4)), let m = Int(raw.dropFirst(4).prefix(2)),
              let d = Int(raw.dropFirst(6).prefix(2)), let h = Int(raw.dropFirst(8).prefix(2)),
              let mi = Int(raw.suffix(2)) else { return raw }
        return String(format: "%04d-%02d-%02d %02d:%02d", y, m, d, h, mi)
    }
    static var label: String { "v\(version) · build \(build)" }
}

// MARK: - 主界面

struct ContentView: View {
    @ObservedObject var model: MonitorModel

    private var latencyColor: Color {
        guard let line = model.statLines.first(where: { $0.0 == "估算延迟" })?.1,
              let ms = Double(line.replacingOccurrences(of: " ms", with: "")) else { return Theme.sub }
        if ms <= 15 { return Theme.neon }
        if ms <= 30 { return Theme.amber }
        return Theme.danger
    }

    var body: some View {
        ZStack {
            GridBackground()
            VStack(spacing: 0) {
                header
                content
                footer
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1040, minHeight: 720)
        .alert("⚠ 输出到扬声器会啸叫", isPresented: $model.showSpeakerAlert) {
            Button("取消", role: .cancel) { model.cancelSpeakerSelection() }
            Button("仍然使用", role: .destructive) { model.confirmSpeakerSelection() }
        } message: {
            Text("用内置/外置扬声器做监听时，麦克风会拾取扬声器声音形成回授啸叫。建议使用耳机监听。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("◤").font(mono(16, weight: .bold)).foregroundColor(Theme.neon)
                VStack(alignment: .leading, spacing: 0) {
                    Text("iTraeMIC//LAB").font(mono(18, weight: .bold)).foregroundColor(Theme.neon).tracking(2)
                    Text("REAL-TIME MONITOR CONSOLE v\(AppInfo.version)").font(mono(9)).foregroundColor(Theme.sub).tracking(1.5)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(model.running ? Theme.neon : Theme.sub.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .shadow(color: model.running ? Theme.neon : .clear, radius: 6)
                Text(model.running ? "RUNNING" : (model.busy ? "BINDING" : "STANDBY"))
                    .font(mono(11, weight: .bold))
                    .foregroundColor(model.running ? Theme.neon : Theme.sub)
                    .tracking(1.5)
                    .help("引擎状态：RUNNING=监听中，BINDING=正在切换设备/重建链路，STANDBY=待机")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(Rectangle().stroke(model.running ? Theme.neon.opacity(0.7) : Theme.sub.opacity(0.4), lineWidth: 1))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.panel.opacity(0.85))
        .overlay(Rectangle().fill(Theme.neon.opacity(0.45)).frame(height: 1), alignment: .bottom)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 14) {
            sidebar
            VStack(spacing: 14) {
                meterPanel
                statsPanel
                logPanel
            }
        }
        .padding(14)
    }

    private var sidebar: some View {
        VStack(spacing: 14) {
            GeekPanel(title: "01 / 输入源") {
                devicePicker(devices: model.inputDevices, selection: model.selectedInputID) { model.chooseInput($0) }
                    .help("选择麦克风输入设备。切换后会重建音频链路，监听会短暂中断。")
                if let device = model.inputDevices.first(where: { $0.id == model.selectedInputID }) {
                    Text("\(device.summary) · 系统音量 \(CoreAudioUtil.inputVolume(device.id).map { String(format: "%.0f%%", $0 * 100) } ?? "—")")
                        .font(mono(9))
                        .foregroundColor(Theme.sub)
                        .help("设备采样率/声道数，以及系统输入音量；音量过低会让人声偏小、底噪更明显")
                } else {
                    Text("未检测到输入设备").font(mono(9)).foregroundColor(Theme.danger)
                }
            }

            GeekPanel(title: "02 / 监听输出") {
                devicePicker(devices: model.outputDevices, selection: model.selectedOutputID) { model.chooseOutput($0) }
                    .help("选择监听输出设备。建议用耳机；选扬声器会啸叫。切换后会重建链路。")
                HStack(spacing: 5) {
                    Text("⚠").font(mono(9)).foregroundColor(Theme.amber)
                    Text("不要选扬声器（会啸叫）。默认自动避开扬声器。")
                        .font(mono(9)).foregroundColor(Theme.amber.opacity(0.85))
                }
            }

            GeekPanel(title: "03 / 处理链") {
                PresetSelector(preset: Binding(
                    get: { model.preset },
                    set: { model.preset = $0; model.applySettings() }
                ))
                GeekToggle(label: "降噪", hint: "高频嘶嘶", on: Binding(
                    get: { model.denoise },
                    set: { model.denoise = $0; model.applySettings() }
                ))
                .help("降噪：把 5 kHz 以上高频压低 6 dB，减少“嘶嘶”声；如果人声齿音变闷可以关掉。")
                GeekToggle(label: "噪声门", hint: "静音时闭麦", on: Binding(
                    get: { model.gateEnabled },
                    set: { model.gateEnabled = $0; model.applySettings() }
                ))
                .help("噪声门：安静时自动压低输入，避免底噪一直响。人声被切掉时，调低门限值或关闭它。")
                GeekSlider(label: "噪声门门限", unit: "dB", value: Binding(
                    get: { model.gateLevel },
                    set: { model.gateLevel = $0; model.applySettings() }
                ), range: -70...(-30))
                .help("噪声门门限：低于这个电平的声音被压低。底噪大就往上调（如 -45），说话声被切掉就往下调。")
                GeekSlider(label: "高通滤波", unit: "Hz", value: Binding(
                    get: { model.hpf },
                    set: { model.hpf = $0; model.applySettings() }
                ), range: 20...200)
                .help("高通滤波：切掉该频率以下的低频（空调声、桌面震动、电流嗡声）。人声一般 80~120 Hz。")
                GeekSlider(label: "总增益", unit: "dB", value: Binding(
                    get: { model.makeup },
                    set: { model.makeup = $0; model.applySettings() }
                ), range: -12...18)
                .help("总增益：整条链路的输出音量。底噪明显时建议 0 或负值，不要靠增益补音量。")
                GeekToggle(label: "超低延迟", hint: "64 帧 + 48k", on: Binding(
                    get: { model.ultra },
                    set: { model.setUltra($0) }
                ), accent: Theme.amber)
                .help("超低延迟：把输出采样率对齐到 48 kHz、缓冲压到 64 帧，降低约 2~3 ms 延迟；会临时改输出设备采样率。")
            }

            VStack(spacing: 8) {
                GeekButton(title: model.running ? "◼  停止监听" : "▶  开始监听",
                           color: model.running ? Theme.danger : Theme.neon,
                           filled: !model.running) { model.toggleRun() }
                    .help(model.running ? "停止监听，并恢复原来的系统默认输入/输出" : "开始实时监听：会临时切换系统默认输入/输出并启动音频引擎")
                GeekButton(title: model.measuringNoise ? "检测中…" : "底噪自检 (2s)",
                           color: Theme.amber) { model.measureNoiseFloor() }
                    .help("底噪自检：保持安静 2 秒，测量当前链路的底噪 RMS，并给出调整建议")
                if !model.noiseReport.isEmpty {
                    Text(model.noiseReport).font(mono(10)).foregroundColor(Theme.amber)
                        .help("最近一次底噪自检结果（RMS，越小越安静）")
                }
            }
        }
        .frame(width: 340)
    }

    private func devicePicker(devices: [AudioDevice], selection: AudioDeviceID?,
                              onSelect: @escaping (AudioDeviceID) -> Void) -> some View {
        Menu {
            ForEach(devices) { device in
                Button {
                    onSelect(device.id)
                } label: {
                    Text(device.isSpeaker ? "\(device.name)  ⚠ 扬声器" : device.name)
                }
            }
        } label: {
            HStack {
                Text(devices.first(where: { $0.id == selection })?.name ?? "选择设备")
                    .font(mono(12, weight: .semibold))
                    .foregroundColor(Theme.neon)
                    .lineLimit(1)
                Spacer()
                Text("▾").font(mono(11)).foregroundColor(Theme.sub)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Theme.panelHi)
            .overlay(Rectangle().stroke(Theme.neonSoft.opacity(0.6), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var meterPanel: some View {
        GeekPanel(title: "实时电平 / LEVEL") {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.0f", model.meterPeak))
                        .font(mono(42, weight: .bold))
                        .foregroundColor(model.meterPeak > -3 ? Theme.danger : Theme.neon)
                        .help("PEAK：最近一次峰值电平（dBFS，0 为满量程）。超过 -3 dB 会变红，提示接近削波。")
                    Text("dBFS PEAK").font(mono(9)).foregroundColor(Theme.sub).tracking(1.5)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "RMS  %.1f", model.meterRMS)).font(mono(12)).foregroundColor(Theme.text)
                        .help("RMS：平滑后的平均电平，反映整体音量大小。")
                    Text(String(format: "HOLD %.1f", model.meterHeld)).font(mono(12)).foregroundColor(Theme.sub)
                        .help("HOLD：峰值保持值，会停留几秒便于看清最大值。")
                    if model.clipped {
                        Text("CLIP").font(mono(10, weight: .bold)).foregroundColor(Theme.danger)
                            .help("CLIP：出现削波（超过满量程），请降低总增益或输入音量。")
                    }
                }
            }
            LedMeter(value: model.meterRMS, held: model.meterHeld, peak: model.meterPeak)
                .help("电平条：绿色=正常，黄色=接近峰值，红色=过高；竖线为峰值保持位置。")
            HistoryStrip(history: model.history)
                .help("最近 10 秒的电平变化历史，用来判断底噪是否稳定。")
            HStack {
                Text("← 10 秒电平历史").font(mono(9)).foregroundColor(Theme.sub)
                Spacer()
                Text("-60 → 0 dBFS").font(mono(9)).foregroundColor(Theme.sub)
            }
        }
    }

    private var statsPanel: some View {
        GeekPanel(title: "运行参数 / TELEMETRY") {
            VStack(spacing: 6) {
                ForEach(Array(model.statLines.enumerated()), id: \.offset) { _, line in
                    ReadoutRow(key: line.0, value: line.1,
                               valueColor: line.0 == "估算延迟" ? latencyColor : Theme.text)
                        .help(readoutHelp(line.0))
                }
            }
        }
    }

    private func readoutHelp(_ key: String) -> String {
        switch key {
        case "输入设备": return "当前使用的麦克风输入设备"
        case "监听输出": return "当前监听输出设备，耳机优先"
        case "图采样率": return "音频引擎内部采样率，通常跟随输出设备；超低延迟模式下对齐为 48 kHz"
        case "缓冲帧": return "每次处理的音频帧数。帧数越小延迟越低，但更容易出现爆音"
        case "估算延迟": return "引擎侧估算延迟，不含麦克风和耳机的硬件延迟；绿色 ≤15 ms，黄色 ≤30 ms"
        case "处理链": return "当前启用的处理：高通、存在感、降噪、噪声门、压缩、增益"
        case "系统默认输入": return "系统当前的默认输入设备；监听期间会被临时切换，停止后恢复"
        case "系统默认输出": return "系统当前的默认输出设备；监听期间会被临时切换，停止后恢复"
        default: return key
        }
    }

    private var logPanel: some View {
        GeekPanel(title: "事件日志 / CONSOLE") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.logLines) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(Self.timeFormatter.string(from: line.time))
                                    .font(mono(9))
                                    .foregroundColor(Theme.sub.opacity(0.8))
                                Text(line.text)
                                    .font(mono(10))
                                    .foregroundColor(color(for: line.kind))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .id(line.id)
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .background(Theme.bg.opacity(0.55))
                .overlay(Rectangle().stroke(Theme.neonSoft.opacity(0.3), lineWidth: 1))
                .onChange(of: model.logLines.count) { _, _ in
                    if let last = model.logLines.last {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .help("事件日志：启动、切换设备、权限、引擎异常都会记录在这里；黄/红行值得注意")
    }

    private func color(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .info: return Theme.text.opacity(0.9)
        case .good: return Theme.neon
        case .warn: return Theme.amber
        case .error: return Theme.danger
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("iTrae MicLab \(AppInfo.label) · 本地处理，不上传数据").font(mono(9)).foregroundColor(Theme.sub)
                .help("版本与构建时间。本应用是本地构建，没有自动更新：改完代码需重新打包，并完全退出旧实例后重新打开才会生效。")
            Spacer()
            Text("监听期间会临时切换系统默认输入/输出，停止或退出自动恢复").font(mono(9)).foregroundColor(Theme.sub.opacity(0.7))
                .help("监听期间会临时改系统默认设备，停止或退出时恢复；强制退出不会自动恢复，需到系统设置里手动改回")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Theme.panel.opacity(0.85))
        .overlay(Rectangle().fill(Theme.neon.opacity(0.25)).frame(height: 1), alignment: .top)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 自检模式（命令行 --selftest，用于验证音频链路）

enum SelfTest {
    static func run() {
        let all = CoreAudioUtil.deviceIDs().compactMap { id -> AudioDevice? in
            let ins = CoreAudioUtil.channelCount(id, kAudioObjectPropertyScopeInput)
            let outs = CoreAudioUtil.channelCount(id, kAudioObjectPropertyScopeOutput)
            guard ins > 0 || outs > 0 else { return nil }
            return AudioDevice(id: id, name: CoreAudioUtil.name(id), inputChannels: ins,
                               outputChannels: outs, sampleRate: CoreAudioUtil.sampleRate(id))
        }
        let inputs = all.filter { $0.inputChannels > 0 }
        let outputs = all.filter { $0.outputChannels > 0 }
        print("输入设备：", inputs.map { "\($0.name)[\($0.id)]" }.joined(separator: ", "))
        print("输出设备：", outputs.map { "\($0.name)[\($0.id)]" }.joined(separator: ", "))

        guard let input = inputs.first(where: { $0.name.uppercased().contains("USB") }) ?? inputs.first,
              let output = outputs.first(where: { !$0.isSpeaker }) ?? outputs.first else {
            print("!! 缺少输入/输出设备"); return
        }
        print("选用输入 \(input.name) → 输出 \(output.name)")

        let originalIn = CoreAudioUtil.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let originalOut = CoreAudioUtil.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let originalOutRate = CoreAudioUtil.sampleRate(output.id)

        for ultra in [false, true] {
            let spec = ChainSpec(preset: .light, hpf: 100, gateEnabled: true, gateLevel: -48,
                                 denoise: true, makeup: 2, ultra: ultra,
                                 inputID: input.id, outputID: output.id)
            do {
                let kit = try AudioGraph.build(spec: spec)
                Thread.sleep(forTimeInterval: 1.6)
                let meter = kit.probe.snapshot()
                print(String(format: "  超低延迟=%@ 图速率 %.0fHz 运行=%@ 输入格式 %.0fHz 缓冲 入%u/出%u 延迟 %.1fms 回调%u 电平 RMS %.1f / PEAK %.1f",
                             ultra ? "开" : "关", kit.graphRate,
                             kit.engine.isRunning ? "是" : "否",
                             kit.engine.inputNode.outputFormat(forBus: 0).sampleRate,
                             kit.inputFrames, kit.outputFrames,
                             kit.latencyMs, kit.probe.callbackCount(), meter.rms, meter.peak))
                kit.engine.mainMixerNode.removeTap(onBus: 0)
                kit.engine.stop()
                Thread.sleep(forTimeInterval: 0.3)
            } catch {
                print("  !! 构建失败(超低延迟=\(ultra))：\(error.localizedDescription)")
            }
        }

        // 恢复
        if let originalOut {
            CoreAudioUtil.setSampleRate(originalOut, originalOutRate)
            CoreAudioUtil.setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, originalOut)
        }
        if let originalIn { CoreAudioUtil.setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, originalIn) }
        print("自检结束，系统默认设备已恢复")
    }
}

// MARK: - App 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: MonitorModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct MicLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // AppKit 默认工具提示延迟约 1 秒，这里压到 200 ms
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 200])
    }
    @StateObject private var model = MonitorModel()

    var body: some Scene {
        WindowGroup("iTrae MicLab") {
            ContentView(model: model)
                .onAppear {
                    delegate.model = model
                    model.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
