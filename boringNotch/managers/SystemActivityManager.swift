//
//  SystemActivityManager.swift
//  boringNotch
//

import Combine
import Darwin
import Foundation
import IOKit
import Metal

/// One row for top process lists (CPU %, memory MB, or GPU placeholder).
struct ActivityProcessRow: Identifiable, Equatable {
    let id: Int
    let name: String
    let detail: String

    init(pid: pid_t, name: String, detail: String) {
        self.id = Int(pid)
        self.name = name
        self.detail = detail
    }
}

@MainActor
final class SystemActivityManager: ObservableObject {
    static let shared = SystemActivityManager()

    /// Total CPU utilization (0–100), fraction of all cores busy vs idle in the sample window.
    @Published private(set) var cpuTotalPercent: Double = 0

    /// Physical memory used as a fraction of total RAM (0–100).
    @Published private(set) var memoryUsedPercent: Double = 0

    @Published private(set) var physicalMemoryBytes: UInt64 = 0

    /// Best-effort GPU utilization; nil when not available.
    @Published private(set) var gpuTotalPercent: Double?

    @Published private(set) var gpuDeviceName: String?

    @Published private(set) var gpuMetricsAvailable: Bool = false

    @Published private(set) var topCPU: [ActivityProcessRow] = []
    @Published private(set) var topMemory: [ActivityProcessRow] = []
    @Published private(set) var topGPU: [ActivityProcessRow] = []

    @Published private(set) var lastUpdated: Date?

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 1.0

    private var previousHostTicks: host_cpu_load_info?
    private var previousHostSampleTime: Date?

    private var previousTaskCPUTime: [pid_t: UInt64] = [:]
    private var previousCPUSampleTime: Date?

    private var gpuProbeDone = false

    private init() {
        probeGPUDeviceNameOnce()
    }

    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
        tick()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        previousHostTicks = nil
        previousHostSampleTime = nil
        previousTaskCPUTime.removeAll()
        previousCPUSampleTime = nil
    }

    private func probeGPUDeviceNameOnce() {
        guard !gpuProbeDone else { return }
        gpuProbeDone = true
        if let device = MTLCreateSystemDefaultDevice() {
            gpuDeviceName = device.name
        } else {
            gpuDeviceName = nil
        }
        gpuMetricsAvailable = false
        gpuTotalPercent = nil
        topGPU = placeholderGPURows()
    }

    private func placeholderGPURows() -> [ActivityProcessRow] {
        (0 ..< 3).map { i in
            ActivityProcessRow(pid: pid_t(-1 - i), name: "—", detail: "Unavailable")
        }
    }

    private func tick() {
        let now = Date()

        updateHostCPU(now: now)
        updateMemoryPressure()
        updateProcessRankings(now: now)
        updateGPUUtilization()

        lastUpdated = now
    }

    private func updateGPUUtilization() {
        guard let snapshot = readAGXSnapshot() else {
            gpuMetricsAvailable = false
            gpuTotalPercent = nil
            topGPU = placeholderGPURows()
            return
        }

        if gpuDeviceName == nil, let model = snapshot.model {
            gpuDeviceName = model
        }

        guard let util = snapshot.deviceUtilization else {
            gpuMetricsAvailable = false
            gpuTotalPercent = nil
            topGPU = placeholderGPURows()
            return
        }

        gpuMetricsAvailable = true
        gpuTotalPercent = min(max(util, 0), 100)

        var rows: [ActivityProcessRow] = []
        if let pid = snapshot.lastSubmissionPID {
            rows.append(
                ActivityProcessRow(
                    pid: pid,
                    name: processName(pid: pid),
                    detail: "Last submitter"
                )
            )
        }

        while rows.count < 3 {
            rows.append(
                ActivityProcessRow(
                    pid: pid_t(-(rows.count + 1)),
                    name: "—",
                    detail: "No process data"
                )
            )
        }
        topGPU = rows
    }

    private struct AGXSnapshot {
        let model: String?
        let deviceUtilization: Double?
        let lastSubmissionPID: pid_t?
    }

    private func readAGXSnapshot() -> AGXSnapshot? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var bestSnapshot: AGXSnapshot?
        var bestUtil = -1.0

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard
                let perfCF = IORegistryEntryCreateCFProperty(
                    service,
                    "PerformanceStatistics" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue(),
                let perf = perfCF as? [String: Any]
            else {
                continue
            }

            let model = (IORegistryEntryCreateCFProperty(
                service,
                "model" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String)

            let agc = IORegistryEntryCreateCFProperty(
                service,
                "AGCInfo" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any]

            let util = numberValue(perf["Device Utilization %"])
                ?? average(numberValue(perf["Renderer Utilization %"]), numberValue(perf["Tiler Utilization %"]))
            let pid = agc.flatMap { dict in
                if let n = dict["fLastSubmissionPID"] as? NSNumber { return pid_t(n.int32Value) }
                if let i = dict["fLastSubmissionPID"] as? Int { return pid_t(i) }
                return nil
            }

            let snapshot = AGXSnapshot(model: model, deviceUtilization: util, lastSubmissionPID: pid)
            if let util, util > bestUtil {
                bestUtil = util
                bestSnapshot = snapshot
            } else if bestSnapshot == nil {
                bestSnapshot = snapshot
            }
        }

        return bestSnapshot
    }

    private func numberValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    private func average(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }

    private func updateHostCPU(now: Date) {
        guard let ticks = readHostCPUTicks() else { return }

        if let prevTicks = previousHostTicks, let prevTime = previousHostSampleTime {
            let elapsed = max(now.timeIntervalSince(prevTime), 0.001)

            func tvals(_ info: host_cpu_load_info) -> (UInt64, UInt64, UInt64, UInt64) {
                let t = info.cpu_ticks
                return (UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3))
            }

            let cur = tvals(ticks)
            let prev = tvals(prevTicks)

            let dUser = cur.0 &- prev.0
            let dSystem = cur.1 &- prev.1
            let dIdle = cur.2 &- prev.2
            let dNice = cur.3 &- prev.3

            let dBusy = dUser &+ dSystem &+ dNice
            let dTotal = dBusy &+ dIdle

            if dTotal > 0 {
                let ratio = Double(dBusy) / Double(dTotal)
                cpuTotalPercent = min(max(ratio * 100.0, 0), 100)
            }
            _ = elapsed // reserved if we switch to load-based metrics
        }

        previousHostTicks = ticks
        previousHostSampleTime = now
    }

    private func readHostCPUTicks() -> host_cpu_load_info? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info
    }

    private func updateMemoryPressure() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else { return }

        var memSize = UInt64(0)
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &len, nil, 0)

        physicalMemoryBytes = memSize

        let usedPages = UInt64(stats.wire_count) &+ UInt64(stats.active_count) &+ UInt64(stats.compressor_page_count)
        let usedBytes = usedPages &* UInt64(pageSize)

        if memSize > 0 {
            memoryUsedPercent = min(100, Double(usedBytes) / Double(memSize) * 100.0)
        }
    }

    private func updateProcessRankings(now: Date) {
        let pids = listAllPIDs()
        guard !pids.isEmpty else { return }

        var taskInfos: [(pid: pid_t, name: String, resident: UInt64, cpuNanos: UInt64)] = []

        for pid in pids {
            guard pid > 0 else { continue }
            var taskInfo = proc_taskinfo()
            let got = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
            guard got == Int32(MemoryLayout<proc_taskinfo>.size) else { continue }

            let resident = taskInfo.pti_resident_size
            let cpuNanos = taskInfo.pti_total_user &+ taskInfo.pti_total_system
            let name = processName(pid: pid)

            taskInfos.append((pid, name, resident, cpuNanos))
        }

        let memSorted = taskInfos.sorted { $0.resident > $1.resident }
        topMemory = Array(memSorted.prefix(3)).map { t in
            let mb = Double(t.resident) / 1024.0 / 1024.0
            return ActivityProcessRow(pid: t.pid, name: t.name, detail: String(format: "%.0f MB", mb))
        }

        if let prevTime = previousCPUSampleTime {
            let elapsedNs = max(now.timeIntervalSince(prevTime) * 1_000_000_000.0, 1.0)

            var usages: [(pid: pid_t, name: String, pct: Double)] = []

            for t in taskInfos {
                guard let prevNanos = previousTaskCPUTime[t.pid] else { continue }
                let delta = Double(t.cpuNanos &- prevNanos)
                let pct = delta / elapsedNs * 100.0
                if pct.isFinite, pct > 0.05 {
                    usages.append((t.pid, t.name, pct))
                }
            }

            usages.sort { $0.pct > $1.pct }
            topCPU = Array(usages.prefix(3)).map { u in
                ActivityProcessRow(pid: u.pid, name: u.name, detail: String(format: "%.0f%%", min(u.pct, 999)))
            }
        }

        var nextMap: [pid_t: UInt64] = [:]
        nextMap.reserveCapacity(taskInfos.count)
        for t in taskInfos {
            nextMap[t.pid] = t.cpuNanos
        }
        previousTaskCPUTime = nextMap
        previousCPUSampleTime = now
    }

    private func listAllPIDs() -> [pid_t] {
        let nbytes = Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0))
        guard nbytes > 0 else { return [] }
        let count = nbytes / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let ret = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(nbytes))
        guard ret > 0 else { return [] }
        return pids.filter { $0 > 0 }
    }

    private func processName(pid: pid_t) -> String {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN (typically 4096)
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLen > 0 {
            let path = String(cString: pathBuffer)
            return (path as NSString).lastPathComponent
        }
        var nameBuf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        let name = String(cString: nameBuf)
        return name.isEmpty ? "(\(pid))" : name
    }
}
