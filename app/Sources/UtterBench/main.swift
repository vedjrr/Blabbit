// utter-bench (G6): measures what `make bench` reports and writes
// bench/results/<date>.json plus docs/BENCHMARKS.md. Anything this machine
// can't measure right now (no live microphone, locked screen) is recorded as
// unavailable with the reason; nothing is estimated or faked.
import AppKit
import ApplicationServices
import Foundation
import UtterCore
import UtterKit

// MARK: Helpers

func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to &- from) / 1_000_000 }
func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((p / 100 * Double(sorted.count - 1)).rounded())))
    return sorted[index]
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
    return s(usage.ru_utime) + s(usage.ru_stime)
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(cString: buffer)
}

func sysctlInt(_ name: String) -> UInt64 {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    sysctlbyname(name, &value, &size, nil, 0)
    return value
}

func run(_ launchPath: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

/// Samples this process's resident size every 10 ms while `body` runs.
func peakResident<T>(_ body: () throws -> T) rethrows -> (T, UInt64) {
    let peak = PeakBox()
    let stop = PeakBox()
    let sampler = Thread {
        while stop.value == 0 {
            peak.max(processMemory().residentBytes)
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    sampler.start()
    defer { stop.max(1) }
    let result = try body()
    peak.max(processMemory().residentBytes)
    return (result, peak.value)
}

final class PeakBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: UInt64 = 0
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return v }
    func max(_ x: UInt64) { lock.lock(); v = Swift.max(v, x); lock.unlock() }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fixtures: [(wav: URL, reference: String)] = {
    let dir = root.appendingPathComponent("fixtures/audio")
    let wavs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
    return wavs.compactMap { wav in
        (try? String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)).map { (wav, $0) }
    }
}()

var report: [String: Any] = [:]
let date = ISO8601DateFormatter().string(from: Date())
report["date"] = date
report["git"] = run("/usr/bin/git", ["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
report["runtime"] = coreVersion()
report["machine"] = [
    "cpu": sysctlString("machdep.cpu.brand_string"),
    "model": sysctlString("hw.model"),
    "memory_gb": Double(sysctlInt("hw.memsize")) / 1_073_741_824,
    "macos": ProcessInfo.processInfo.operatingSystemVersionString,
]
report["conditions"] = [
    "lid_closed": SystemState.lidClosed, "display_asleep": SystemState.displayAsleep, "screen_locked": SystemState.screenLocked,
]
func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
guard fixtures.count >= 5 else {
    log("utter-bench: expected ≥ 5 fixtures in fixtures/audio (run from the repository root).")
    exit(1)
}

// MARK: 1. Models: load, warm-up, RTF, peak RSS, CPU

log("models…")
var modelRows: [[String: Any]] = []
var failed = false
let manager = await MainActor.run { ModelManager(modelsDirectory: ModelLocation.modelsDirectory, defaults: UserDefaults(suiteName: "dev.utter.bench")!) }
let installed = await MainActor.run { manager.installedEntries }
for entry in installed {
    guard let path = await MainActor.run(body: { manager.path(for: entry.id) }) else { continue }
    let engine = UtterEngine()
    let baseline = processMemory()
    do {
        let (info, loadPeak) = try peakResident { try engine.loadModel(path: path) }
        var clips: [[String: Any]] = []
        var errors = 0.0, words = 0.0
        let cpuStart = cpuSeconds(), wallStart = nowNs()
        var inferenceTotal = 0.0, audioTotal = 0.0
        let (_, runPeak) = try peakResident { () throws -> Void in
            for (wav, reference) in fixtures {
                let pcm = try loadWav16kMono(path: wav.path)
                var times: [Double] = []
                var text = ""
                for _ in 0..<3 {
                    let r = try engine.transcribe(pcm: pcm, options: DictationOptions(language: nil, translate: false, initialPrompt: nil))
                    times.append(r.inferenceMs)
                    text = r.text
                    inferenceTotal += r.inferenceMs
                    audioTotal += Double(r.audioMs)
                }
                let p50 = percentile(times, 50) ?? 0
                let audioMs = Double(pcm.count) / 16
                let refWords = Double(reference.split(whereSeparator: \.isWhitespace).count)
                let wer = wordErrorRate(reference: reference, hypothesis: text)
                errors += wer * refWords
                words += refWords
                clips.append(["clip": wav.lastPathComponent, "audio_ms": round1(audioMs), "infer_ms_p50": round1(p50),
                              "rtf": (p50 / audioMs * 1000).rounded() / 1000, "wer": (wer * 1000).rounded() / 1000])
            }
        }
        let wall = ms(wallStart, nowNs()) / 1000
        let cpu = cpuSeconds() - cpuStart
        modelRows.append([
            "id": entry.id, "name": entry.name,
            "load_ms": round1(info.loadMs), "warmup_ms": round1(info.warmupMs),
            "rtf_mean": (inferenceTotal / max(audioTotal, 1) * 1000).rounded() / 1000,
            "wer": (errors / max(words, 1) * 1000).rounded() / 1000,
            // Peak resident size of the bench process while this model loaded and ran,
            // and the part added by the model (bench baseline subtracted).
            "peak_rss_mb": round1(Double(max(loadPeak, runPeak)) / 1_048_576),
            "model_rss_mb": round1(Double(Int64(max(loadPeak, runPeak)) - Int64(baseline.residentBytes)) / 1_048_576),
            "cpu_percent_during_inference": round1(cpu / max(wall, 0.001) * 100),
            "load_count": engine.loadCount(),
            "clips": clips,
        ])
        log("  \(entry.id): load \(Int(info.loadMs)) ms, RTF \(round1(inferenceTotal / max(audioTotal, 1) * 1000) / 1000)")
    } catch let error as CoreError {
        log("  \(entry.id) FAILED: \(error.logDetail)")
        failed = true
    }
    engine.unload()
}
report["models"] = modelRows
if modelRows.isEmpty { log("No models installed. Run `make models`."); exit(1) }

// MARK: 1b. A short utterance right away vs after the Mac sat idle
// (the GPU clocks down; the first dictation after a pause pays to wake it).

log("idle wake…")
if let entry = installed.first(where: { $0.recommended }) ?? installed.first,
   let path = await MainActor.run(body: { manager.path(for: entry.id) }) {
    let engine = UtterEngine()
    if (try? engine.loadModel(path: path)) != nil, let clip = try? loadWav16kMono(path: fixtures[0].wav.path) {
        let short = Array(clip.prefix(8_000 + 16_000 / 2)) // ~1 s of speech
        func once() -> Double {
            (try? engine.transcribe(pcm: short, options: DictationOptions(language: nil, translate: false, initialPrompt: nil)).inferenceMs) ?? -1
        }
        let hot = (0..<5).map { _ in once() }
        var afterIdle: [String: Double] = [:]
        for seconds in [0.2, 2.0, 10.0, 30.0] {
            pause(seconds)
            afterIdle[seconds < 1 ? "\(Int(seconds * 1000))ms" : "\(Int(seconds))s"] = round1(once())
        }
        report["idle_wake"] = ["model": entry.id, "audio_ms": short.count / 16, "back_to_back_ms_p50": round1(percentile(hot, 50) ?? -1),
                               "after_idle_ms": afterIdle]
        log("  back-to-back \(round1(percentile(hot, 50) ?? -1)) ms, after idle \(afterIdle)")
    }
    engine.unload()
}

// MARK: 2. Text pipeline

log("text pipeline…")
do {
    var settings = TextPipelineSettings()
    settings.vocabulary = ["HoldMyCode", "Decivra", "Maynooth", "PostgreSQL", "TypeScript", "SwiftUI", "WhisperKit"]
    let fiveMinutes = String(repeating: "um so we moved the backend to type script and post gur SQL last week ", count: 60) // ~900 words
    var times: [Double] = []
    for _ in 0..<5 {
        let t0 = nowNs()
        _ = await TextPipeline(settings: settings).run(fiveMinutes)
        times.append(ms(t0, nowNs()))
    }
    let short = "um so we moved the backend to type script"
    var shortTimes: [Double] = []
    for _ in 0..<20 {
        let t0 = nowNs()
        _ = await TextPipeline(settings: settings).run(short)
        shortTimes.append(ms(t0, nowNs()))
    }
    report["text_pipeline"] = [
        "clean_900_words_ms_p50": round1(percentile(times, 50) ?? 0),
        "clean_short_ms_p50": (percentile(shortTimes, 50).map { ($0 * 100).rounded() / 100 }) ?? 0,
    ]
}

// MARK: 3. Capture start (G1 key-down → first audio, recorder part)

log("capture…")
if let reason = SystemState.liveInputUnavailableReason {
    report["capture"] = ["available": false, "reason": "no live microphone: \(reason)"]
} else {
    let queue = DispatchQueue(label: "bench.audio")
    let recorder = AudioRecorder(queue: queue)
    func measure(_ n: Int, gap: TimeInterval) -> [Double] {
        var firsts: [Double] = []
        for _ in 0..<n {
            let t0 = nowNs()
            guard (try? queue.sync { try recorder.start() }) != nil else { continue }
            Thread.sleep(forTimeInterval: 0.25)
            let rec = queue.sync { recorder.stop(releaseNs: nowNs()) }
            if let first = rec.firstSampleNs { firsts.append(ms(t0, first)) }
            Thread.sleep(forTimeInterval: gap)
        }
        return firsts
    }
    _ = try? queue.sync { try recorder.prepare() }
    let cold = measure(5, gap: 1.5)
    _ = try? queue.sync { try recorder.setKeepReady(true) }
    pause( 0.5)
    let warm = measure(5, gap: 0.3)
    _ = try? queue.sync { try recorder.setKeepReady(false) }
    report["capture"] = [
        "available": true,
        "start_to_first_sample_ms_cold": cold.map(round1), "start_to_first_sample_ms_warm": warm.map(round1),
        "cold_p50": round1(percentile(cold, 50) ?? -1), "warm_p50": round1(percentile(warm, 50) ?? -1),
    ]
}

// MARK: 4. Insertion

log("insertion…")
do {
    // Paste path on a private pasteboard: snapshot, write, ⌘V handed over (the
    // simulated target reads at once). The text reaches the app at "paste sent".
    var pasteSent: [Double] = []
    for _ in 0..<10 {
        let t: Double? = await MainActor.run { () -> PasteInserter in
            let pb = NSPasteboard(name: NSPasteboard.Name("dev.utter.bench.\(UUID().uuidString)"))
            pb.clearContents()
            pb.setString("user's clipboard", forType: .string)
            let inserter = PasteInserter(pasteboard: pb, checkSecureInput: false) {
                _ = pb.string(forType: .string)
                return nil
            }
            inserter.quietPeriod = .milliseconds(20)
            return inserter
        }.benchInsert()
        if let t { pasteSent.append(t) }
    }
    var insertion: [String: Any] = [
        "paste_to_sent_ms_p50": round1(percentile(pasteSent, 50) ?? -1),
        "paste_note": "private pasteboard; snapshot + write + ⌘V handed over; restore happens after the target reads",
    ]
    if SystemState.screenLocked || SystemState.displayAsleep || !AXIsProcessTrusted() {
        insertion["accessibility"] = ["available": false,
                                      "reason": SystemState.screenLocked ? "screen locked" : (SystemState.displayAsleep ? "display asleep" : "not trusted for Accessibility")]
    } else {
        insertion["accessibility"] = benchAccessibility()
    }
    report["insertion"] = insertion
}

// MARK: 5. App launch, idle RSS and CPU

log("app launch…")
let appBinary = root.appendingPathComponent("build/Utter.app/Contents/MacOS/Utter")
if FileManager.default.isExecutableFile(atPath: appBinary.path) {
    let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("utter-bench-\(UUID().uuidString).log")
    var launches: [[String: Any]] = []
    for _ in 0..<3 {
        try? FileManager.default.removeItem(at: logFile)
        let p = Process()
        p.executableURL = appBinary
        p.environment = ProcessInfo.processInfo.environment.merging(
            ["UTTER_LOG_FILE": logFile.path, "UTTER_BENCH_SECOND_INSTANCE": "1"]) { $1 }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let t0 = nowNs()
        guard (try? p.run()) != nil else { break }
        var tapMs: Double?, readyMs: Double?
        while ms(t0, nowNs()) < 20_000, readyMs == nil {
            let text = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            if tapMs == nil, text.contains("hotkey tap started") { tapMs = ms(t0, nowNs()) }
            if text.contains("model_load model=") { readyMs = ms(t0, nowNs()) }
            pause( 0.005)
        }
        pause( 5) // settle, then sample idle cost
        let ps = run("/bin/ps", ["-o", "rss=,%cpu=", "-p", "\(p.processIdentifier)"]).split(whereSeparator: \.isWhitespace)
        launches.append([
            "launch_to_shortcut_ready_ms": tapMs.map(round1) ?? -1,
            "launch_to_model_ready_ms": readyMs.map(round1) ?? -1,
            "idle_rss_mb": ps.count >= 1 ? round1((Double(ps[0]) ?? 0) / 1024) : -1,
            "idle_cpu_percent": ps.count >= 2 ? (Double(ps[1]) ?? -1) : -1,
        ])
        p.terminate()
        p.waitUntilExit()
    }
    report["app"] = ["launches": launches,
                     "launch_to_model_ready_ms_p50": round1(percentile(launches.compactMap { $0["launch_to_model_ready_ms"] as? Double }, 50) ?? -1),
                     "idle_rss_mb_p50": round1(percentile(launches.compactMap { $0["idle_rss_mb"] as? Double }, 50) ?? -1)]
} else {
    report["app"] = ["available": false, "reason": "build/Utter.app missing: run `make build`"]
}

// MARK: 6. Real dictations from the app log (key-down → capture, release → insert)

let appLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Utter/utter.log")
let lines = ((try? String(contentsOf: appLog, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains(" dictation ") }
func field(_ name: String) -> [Double] {
    lines.compactMap { line in
        guard let range = line.range(of: " \(name)=") else { return nil }
        return Double(line[range.upperBound...].prefix { !$0.isWhitespace })
    }
}
var dictation: [String: Any] = ["count": lines.count, "source": "~/Library/Logs/Utter/utter.log dictation lines"]
for name in ["keydown_to_first_sample_ms", "keydown_to_overlay_ms", "event_to_callback_ms", "release_to_transcribed_ms", "release_to_insert_done_ms", "inference_ms"] {
    let values = field(name)
    if !values.isEmpty {
        dictation[name] = ["n": values.count, "p50": round1(percentile(values, 50)!), "p95": round1(percentile(values, 95)!)]
    }
}
report["dictation_from_app_log"] = dictation

// MARK: Output

let outDir = root.appendingPathComponent("bench/results")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let day = String(date.prefix(10))
let jsonURL = outDir.appendingPathComponent("\(day).json")
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: jsonURL)
try writeMarkdown(report, to: root.appendingPathComponent("docs/BENCHMARKS.md"), json: "bench/results/\(day).json")
log("Wrote \(jsonURL.path) and docs/BENCHMARKS.md")
exit(failed ? 1 : 0)
