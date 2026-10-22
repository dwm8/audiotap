// AudioTap: menu bar app. Click the icon to start recording everything the Mac plays; click again to stop.
// Captures through a Core Audio global process tap (macOS 14.2+) and streams PCM into ffmpeg for MP3.
import AppKit
import AudioToolbox
import CoreAudio

let ffmpegPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
let outputDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/AudioTap")

func log(_ s: String) {
    FileHandle.standardError.write("\(Date()) \(s)\n".data(using: .utf8)!)
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw NSError(domain: "AudioTap", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(what) failed (\(status))"]) }
}

func defaultOutputUID() throws -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device), "default output device")
    addr.mSelector = kAudioDevicePropertyDeviceUID
    var uid: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid), "output device UID")
    return uid!.takeRetainedValue() as String
}

// Audio process objects for the given bundle IDs. systemsoundserverd plays notification and alert sounds.
func audioProcesses(_ bundleIDs: Set<String>) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter { id in
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bid: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &bid) == noErr, let b = bid?.takeRetainedValue() as String? else { return false }
        return bundleIDs.contains(b)
    }
}

let trimKey = "trimSilence"

// Cuts leading and trailing silence (below -60 dB) from an MP3 in place, keeping a short pad.
// Uses a stream copy, so the audio is not re-encoded.
func trimSilence(_ url: URL) {
    guard let ffmpegPath else { return }
    func run(_ args: [String]) -> (Int32, String) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        p.arguments = ["-hide_banner", "-nostats"] + args
        p.standardError = out
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text)
    }
    let (_, report) = run(["-i", url.path, "-af", "silencedetect=noise=-60dB:d=0.3", "-f", "null", "-"])
    func values(_ key: String) -> [Double] {
        report.components(separatedBy: "\n").compactMap { line in
            guard let r = line.range(of: key + ": ") else { return nil }
            return Double(line[r.upperBound...].prefix { "0123456789.".contains($0) })
        }
    }
    guard let d = report.range(of: "Duration: ").map({ report[$0.upperBound...].prefix(11).split(separator: ":").compactMap { Double($0) } }),
          d.count == 3 else { return }
    let duration = d[0] * 3600 + d[1] * 60 + d[2]
    let starts = values("silence_start"), ends = values("silence_end")
    let pad = 0.15
    var from = 0.0, to = duration
    if let s = starts.first, s < 0.05, let e = ends.first { from = max(0, e - pad) }
    if let s = starts.last, let e = ends.last, abs(e - duration) < 0.1, s > from { to = min(duration, s + pad) }
    guard from > 0 || to < duration, to - from > 0.5 else { return }

    let tmp = url.deletingPathExtension().appendingPathExtension("trim.mp3")
    let (status, _) = run(["-loglevel", "error", "-y", "-ss", String(format: "%.3f", from), "-to", String(format: "%.3f", to),
                           "-i", url.path, "-c", "copy", tmp.path])
    guard status == 0 else { try? FileManager.default.removeItem(at: tmp); log("trim failed"); return }
    _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    log(String(format: "trimmed %.2f-%.2f of %.2f s", from, to, duration))
}

final class Recorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var ffmpeg: Process?
    private var pipe: Pipe?
    private let ioQueue = DispatchQueue(label: "audiotap.io", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "audiotap.write")
    private(set) var file: URL?

    func start() throws {
        guard let ffmpegPath else { throw NSError(domain: "AudioTap", code: 1, userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found; brew install ffmpeg"]) }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: audioProcesses(["systemsoundserverd"]))
        desc.uuid = UUID()
        desc.name = "AudioTap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create tap (is Audio Recording allowed in Privacy settings?)")

        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "tap format")
        let channels = Int(asbd.mChannelsPerFrame)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        log("tap format: \(asbd.mSampleRate) Hz, \(channels) ch, \(asbd.mBitsPerChannel) bit, flags \(asbd.mFormatFlags)")
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else {
            throw NSError(domain: "AudioTap", code: 2, userInfo: [NSLocalizedDescriptionKey: "unexpected tap format"])
        }

        let outputUID = try defaultOutputUID()
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID), "create aggregate device")

        // The IO proc delivers frames at the aggregate device's rate (the output device's), not the tap's reported rate.
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sampleRate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        try check(AudioObjectGetPropertyData(aggregateID, &rateAddr, 0, nil, &size, &sampleRate), "device sample rate")
        log("device sample rate: \(sampleRate) Hz")

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = outputDir.appendingPathComponent("AudioTap \(stamp.string(from: Date())).mp3")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-f", "f32le", "-ar", String(Int(sampleRate)), "-ac", String(channels),
                       "-i", "pipe:0", "-codec:a", "libmp3lame", "-b:a", "192k", url.path]
        let pipe = Pipe()
        p.standardInput = pipe
        try p.run()
        self.ffmpeg = p
        self.pipe = pipe
        self.file = url

        let writer = pipe.fileHandleForWriting
        let writeQueue = self.writeQueue
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            var data: Data
            if interleaved || buffers.count == 1 {
                guard let b = buffers.first, let mem = b.mData else { return }
                data = Data(bytes: mem, count: Int(b.mDataByteSize))
            } else {
                let frames = Int(buffers[0].mDataByteSize) / 4
                var out = [Float](repeating: 0, count: frames * buffers.count)
                for (c, b) in buffers.enumerated() {
                    guard let mem = b.mData else { continue }
                    let src = mem.assumingMemoryBound(to: Float.self)
                    for f in 0..<frames { out[f * buffers.count + c] = src[f] }
                }
                data = out.withUnsafeBytes { Data($0) }
            }
            writeQueue.async { try? writer.write(contentsOf: data) }
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start device")
        log("recording to \(url.path)")
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        ioQueue.sync {}
        writeQueue.sync {}
        try? pipe?.fileHandleForWriting.close()
        ffmpeg?.waitUntilExit()
        if let ffmpeg { log("ffmpeg exited \(ffmpeg.terminationStatus)") }
        ffmpeg = nil
        pipe = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let recorder = Recorder()
    var startedAt: Date?
    var timer: Timer?
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: [trimKey: true])
        menu.addItem(withTitle: "Open Recordings Folder", action: #selector(openFolder), keyEquivalent: "")
        menu.addItem(withTitle: "Trim Silence at Start and End", action: #selector(toggleTrim), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AudioTap", action: #selector(quit), keyEquivalent: "q")
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        render()
    }

    func render() {
        guard let button = item.button else { return }
        if let startedAt {
            let s = Int(Date().timeIntervalSince(startedAt))
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
                .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
            button.title = String(format: " %d:%02d", s / 60, s % 60)
            button.toolTip = "Recording. Click to stop."
        } else {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record system audio")
            button.title = ""
            button.toolTip = "Click to record system audio. Right-click for options."
        }
    }

    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            menu.item(withTitle: "Trim Silence at Start and End")?.state = UserDefaults.standard.bool(forKey: trimKey) ? .on : .off
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        if startedAt == nil {
            do {
                try recorder.start()
                startedAt = Date()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.render() }
            } catch {
                recorder.stop()
                log("start failed: \(error.localizedDescription)")
                alert("Couldn't start recording", error.localizedDescription)
            }
        } else {
            timer?.invalidate()
            startedAt = nil
            recorder.stop()
            if let file = recorder.file {
                let trim = UserDefaults.standard.bool(forKey: trimKey)
                DispatchQueue.global(qos: .userInitiated).async {
                    if trim { trimSilence(file) }
                    DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            }
        }
        render()
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc func openFolder() {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputDir)
    }

    @objc func toggleTrim() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: trimKey), forKey: trimKey)
    }

    @objc func quit() {
        if startedAt != nil { recorder.stop() }
        NSApp.terminate(nil)
    }
}

// `AudioTap --test <seconds>` records without the menu bar, for checking the capture path.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--test", let secs = Double(CommandLine.arguments[2]) {
    let r = Recorder()
    do { try r.start() } catch { log("start failed: \(error.localizedDescription)"); exit(1) }
    Thread.sleep(forTimeInterval: secs)
    r.stop()
    print(r.file!.path)
    exit(0)
}
// `AudioTap --trim <file.mp3>` runs the silence trim on an existing file.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--trim" {
    trimSilence(URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
