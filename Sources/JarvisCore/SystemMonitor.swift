import Foundation
import Darwin
import IOKit
import IOKit.ps
import CoreWLAN

/// A point-in-time reading of the Mac's health. Cheap to take: a few kernel calls, no processes.
public struct MacSnapshot: Sendable, Equatable {
    public struct Battery: Sendable, Equatable {
        public var percent: Int
        public var charging: Bool
        public var onAC: Bool
        public var minutesLeft: Int?      // to empty, or to full while charging
        public var cycles: Int?
        public var healthPercent: Int?    // current full charge as a share of the design capacity
        public var condition: String?     // "Good", "Fair", "Check Battery"...
        public var temperatureC: Double?
    }

    public var cpu: Double                // 0...1 across all cores
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var swapUsed: UInt64
    public var pressure: String           // normal, warning, critical
    public var diskFree: Int64            // includes space macOS can purge on demand
    public var diskTotal: Int64
    public var battery: Battery?
    public var thermal: String            // nominal, fair, serious, critical
    public var uptime: TimeInterval
    public var wifiOn: Bool?
    public var wifiSignal: Int?           // RSSI in dBm
    public var online: Bool

    public var memoryFraction: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) }
    public var diskUsedFraction: Double { diskTotal == 0 ? 0 : 1 - Double(diskFree) / Double(diskTotal) }
}

public struct ProcessUsage: Sendable, Equatable {
    public let name: String
    public let cpu: Double      // percent of one core
    public let memoryMB: Int
}

public final class SystemMonitor: @unchecked Sendable {
    public static let shared = SystemMonitor()

    private let lock = NSLock()
    private var lastTicks: (busy: UInt64, total: UInt64)?

    // MARK: Static facts

    public static let model: String = sysctlString("hw.model") ?? "Mac"
    public static let chip: String = sysctlString("machdep.cpu.brand_string") ?? "Apple silicon"
    public static let macOS: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }()

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    // MARK: Snapshot

    public func snapshot() -> MacSnapshot {
        let (used, total) = memory()
        let (free, capacity) = disk()
        let wifi = CWWiFiClient.shared().interface()
        let wifiOn = wifi?.powerOn()
        let rssi = wifi.flatMap { $0.powerOn() ? $0.rssiValue() : nil }
        return MacSnapshot(
            cpu: cpuLoad(),
            memoryUsed: used,
            memoryTotal: total,
            swapUsed: swap(),
            pressure: pressure(),
            diskFree: free,
            diskTotal: capacity,
            battery: battery(),
            thermal: Self.thermalName(ProcessInfo.processInfo.thermalState),
            uptime: uptime(),
            wifiOn: wifiOn,
            wifiSignal: rssi.flatMap { $0 == 0 ? nil : $0 },
            online: Self.hasNetwork()
        )
    }

    /// Share of CPU time spent busy since the previous call. The first call reads since boot.
    private func cpuLoad() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        return lock.withLock {
            defer { lastTicks = (busy, total) }
            guard let last = lastTicks, total > last.total else { return total == 0 ? 0 : Double(busy) / Double(total) }
            return Double(busy - last.busy) / Double(total - last.total)
        }
    }

    /// Matches Activity Monitor's "Memory Used": app memory, wired and compressed.
    private func memory() -> (UInt64, UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    private func swap() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    private func pressure() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return "normal" }
        switch level {
        case 4: return "critical"
        case 2: return "warning"
        default: return "normal"
        }
    }

    private var diskCache: (at: Date, free: Int64, total: Int64) = (.distantPast, 0, 0)

    /// Free space counts what macOS can purge on demand. Working that out is slow, so it's cached for a minute.
    private func disk(fresh: Bool = false) -> (Int64, Int64) {
        if !fresh, let c = lock.withLock({ Date().timeIntervalSince(diskCache.at) < 60 ? diskCache : nil }) { return (c.free, c.total) }
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let out = (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
        lock.withLock { diskCache = (Date(), out.0, out.1) }
        return out
    }

    /// Free space right now, bypassing the cache (after a cleanup).
    public func freeSpaceNow() -> Int64 { disk(fresh: true).0 }

    private func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - TimeInterval(boot.tv_sec)
    }

    private func battery() -> MacSnapshot.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = charging ? d[kIOPSTimeToFullChargeKey] as? Int : d[kIOPSTimeToEmptyKey] as? Int
            var b = MacSnapshot.Battery(
                percent: max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur,
                charging: charging, onAC: onAC,
                minutesLeft: minutes.flatMap { $0 > 0 ? $0 : nil },
                condition: d[kIOPSBatteryHealthKey] as? String
            )
            Self.smartBattery(into: &b)
            return b
        }
        return nil
    }

    /// Cycle count, wear and temperature come from the battery controller in the I/O Registry.
    private static func smartBattery(into b: inout MacSnapshot.Battery) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        b.cycles = int("CycleCount")
        if let design = int("DesignCapacity"), design > 0, let full = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") {
            b.healthPercent = min(100, Int((Double(full) / Double(design) * 100).rounded()))
        }
        if let t = int("Temperature"), t > 0 { b.temperatureC = Double(t) / 100 }
    }

    static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func hasNetwork() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            let family = cur.pointee.ifa_addr?.pointee.sa_family
            if flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
               family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                let name = String(cString: cur.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("bridge") { return true }
            }
            p = cur.pointee.ifa_next
        }
        return false
    }

    // MARK: Processes

    /// The busiest apps right now, by CPU and by memory.
    public func topProcesses(limit: Int = 5) async -> (cpu: [ProcessUsage], memory: [ProcessUsage]) {
        let out = await Run.capture("/bin/ps", ["-Aceo", "pcpu=,rss=,comm="], timeout: 5)
        let all: [ProcessUsage] = out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let cpu = Double(parts[0]), let rss = Int(parts[1]) else { return nil }
            return ProcessUsage(name: String(parts[2]), cpu: cpu, memoryMB: rss / 1024)
        }
        let byCPU = Array(all.sorted { $0.cpu > $1.cpu }.prefix(limit))
        let byMem = Array(all.sorted { $0.memoryMB > $1.memoryMB }.prefix(limit))
        return (byCPU, byMem)
    }

    // MARK: Words

    public static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t > 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return f.string(from: t) ?? "\(Int(t / 60)) minutes"
    }

    /// Something worth telling the user about without being asked, and what it's about.
    public struct Alert: Sendable, Equatable {
        public enum Kind: String, Sendable { case battery, storage, memory, thermal, batteryHealth }
        public let kind: Kind
        public let text: String
    }

    public static func alertItems(_ s: MacSnapshot) -> [Alert] {
        var out: [Alert] = []
        if let b = s.battery, !b.onAC, b.percent <= 15 {
            out.append(Alert(kind: .battery, text: "Battery is at \(b.percent)%. Plug in soon."))
        }
        if s.diskTotal > 0, s.diskFree < 10_000_000_000 || Double(s.diskFree) / Double(s.diskTotal) < 0.05 {
            out.append(Alert(kind: .storage, text: "Only \(bytes(s.diskFree)) of disk space is left. I can free some up if you like."))
        }
        if s.pressure == "critical" {
            out.append(Alert(kind: .memory, text: "Memory is under heavy pressure. Closing a few apps will speed things up."))
        }
        if s.thermal == "serious" || s.thermal == "critical" {
            out.append(Alert(kind: .thermal, text: "Your Mac is running hot and may be slowing itself down."))
        }
        if let h = s.battery?.condition, h != "Good", !h.isEmpty {
            out.append(Alert(kind: .batteryHealth, text: "macOS reports the battery condition as \(h)."))
        }
        return out
    }

    public static func alerts(_ s: MacSnapshot) -> [String] { alertItems(s).map(\.text) }

    /// Only the serious cases, for unprompted warnings: memory pressure at its worst, overheating,
    /// a nearly full disk, or a battery about to die. Ordinary busy moments don't count.
    public static func extremeItems(_ s: MacSnapshot) -> [Alert] {
        var out: [Alert] = []
        if s.pressure == "critical" {
            out.append(Alert(kind: .memory, text: "Your Mac has been short of memory for a while, which slows everything down. Closing a few apps will help."))
        }
        if s.thermal == "serious" || s.thermal == "critical" {
            out.append(Alert(kind: .thermal, text: "Your Mac has been running very hot for a while and is slowing itself down to cool off."))
        }
        if s.diskTotal > 0, s.diskFree < 2_000_000_000 || Double(s.diskFree) / Double(s.diskTotal) < 0.02 {
            out.append(Alert(kind: .storage, text: "Your disk is almost full (\(bytes(s.diskFree)) left). Apps may stop saving. I can free some space."))
        }
        if let b = s.battery, !b.onAC, b.percent <= 5 {
            out.append(Alert(kind: .battery, text: "Battery is at \(b.percent)%. Plug in now to avoid losing work."))
        }
        return out
    }

    /// How long a problem has to last before it's worth interrupting the user.
    public static func patience(_ kind: Alert.Kind) -> TimeInterval {
        switch kind {
        case .memory, .storage: return 20 * 60
        case .thermal: return 15 * 60
        case .battery, .batteryHealth: return 0
        }
    }

    /// A plain report the model (or the user) can read.
    public static func report(_ s: MacSnapshot, top: (cpu: [ProcessUsage], memory: [ProcessUsage])? = nil, focus: String = "all") -> String {
        var lines: [String] = ["\(chip) \(model), \(macOS), up \(duration(s.uptime))."]
        let all = focus == "all" || focus.isEmpty
        if all || focus == "cpu" {
            lines.append("CPU: \(Int((s.cpu * 100).rounded()))% busy across \(ProcessInfo.processInfo.activeProcessorCount) cores. Thermal state: \(s.thermal).")
        }
        if all || focus == "memory" {
            lines.append("Memory: \(bytes(Int64(s.memoryUsed))) of \(bytes(Int64(s.memoryTotal))) used (\(Int((s.memoryFraction * 100).rounded()))%), pressure \(s.pressure), swap \(bytes(Int64(s.swapUsed))).")
        }
        if all || focus == "storage" || focus == "disk" {
            lines.append("Storage: \(bytes(s.diskFree)) free of \(bytes(s.diskTotal)) (\(Int((s.diskUsedFraction * 100).rounded()))% used).")
        }
        if all || focus == "battery" {
            if let b = s.battery {
                var t = "Battery: \(b.percent)%, " + (b.charging ? "charging" : (b.onAC ? "on power, not charging" : "on battery"))
                if let m = b.minutesLeft { t += ", about \(duration(TimeInterval(m * 60))) " + (b.charging ? "to full" : "left") }
                if let h = b.healthPercent { t += ". Health \(h)% of original capacity" }
                if let c = b.cycles { t += ", \(c) cycles" }
                if let cond = b.condition { t += ", condition \(cond)" }
                if let temp = b.temperatureC { t += String(format: ", %.0f°C", temp) }
                lines.append(t + ".")
            } else {
                lines.append("Battery: none (desktop Mac).")
            }
        }
        if all || focus == "network" {
            var t = "Network: " + (s.online ? "connected" : "offline")
            if let on = s.wifiOn { t += ", Wi-Fi " + (on ? "on" : "off") }
            if let r = s.wifiSignal { t += " (signal \(r) dBm, " + (r > -60 ? "strong" : r > -72 ? "fair" : "weak") + ")" }
            lines.append(t + ".")
        }
        if let top, all || focus == "processes" || focus == "cpu" || focus == "memory" {
            if !top.cpu.isEmpty {
                lines.append("Busiest by CPU: " + top.cpu.map { "\($0.name) \(Int($0.cpu.rounded()))%" }.joined(separator: ", ") + ".")
            }
            if !top.memory.isEmpty {
                lines.append("Biggest by memory: " + top.memory.map { "\($0.name) \($0.memoryMB) MB" }.joined(separator: ", ") + ".")
            }
        }
        let warn = alerts(s)
        if !warn.isEmpty { lines.append("Attention: " + warn.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }

    /// One or two sentences for speaking when no model is available.
    public static func spokenSummary(_ s: MacSnapshot) -> String {
        var parts: [String] = []
        parts.append("CPU is at \(Int((s.cpu * 100).rounded())) percent and memory at \(Int((s.memoryFraction * 100).rounded())) percent")
        parts.append("\(bytes(s.diskFree)) of storage is free")
        if let b = s.battery { parts.append("the battery is at \(b.percent) percent" + (b.charging ? " and charging" : "")) }
        var out = parts.joined(separator: ", ") + "."
        out = out.prefix(1).uppercased() + out.dropFirst()
        let warn = alerts(s)
        return warn.isEmpty ? out + " Everything looks healthy." : out + " " + warn.joined(separator: " ")
    }
}

/// Runs a fixed program (never a shell string) and returns its output.
public enum Run {
    public static func capture(_ path: String, _ args: [String], timeout: TimeInterval = 20, input: String? = nil) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                let inPipe = Pipe()
                if input != nil { p.standardInput = inPipe }
                do { try p.run() } catch {
                    cont.resume(returning: "Couldn't run \((path as NSString).lastPathComponent).")
                    return
                }
                if let input {
                    inPipe.fileHandleForWriting.write(Data(input.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}
