// TR-100 Machine Report — macOS Edition (native)
// Fork of usgraphics/usgc-machine-report. BSD-3-Clause.
//
// Build:  swiftc -O machine_report.swift -o machine-report
// Usage:  machine-report [--demo]

import Foundation
import CoreGraphics
import IOKit.ps

// Configuration
let reportTitle = "MACHINE REPORT"
let demoMode = CommandLine.arguments.contains("--demo")

// Colors
let C_RESET = "\u{1B}[0m"
let BG_WIN = "\u{1B}[48;2;170;170;170m"
let FG_FRAME = "\u{1B}[38;2;255;255;255m"
let FG_TEXT = "\u{1B}[38;2;0;0;0m"
let FG_LABEL = "\u{1B}[1;38;2;0;0;0m"
let FG_TITLE = "\u{1B}[1;38;2;255;255;255m"
let FG_DIV = "\u{1B}[38;2;255;255;255m"
let FG_BAR = "\u{1B}[38;2;0;170;0m"
let FG_BAR_EMPTY = "\u{1B}[38;2;115;115;115m"
let C_SHADOW = "\u{1B}[48;2;0;0;0m"

// Layout
let MAX_NAME_LEN = 13
let MAX_DATA_LEN = 32
let INDENT = "  "

// MARK: - System queries

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    // Some OIDs are 32-bit; the high half stays zero on little-endian.
    return Int(value)
}

func env(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }

func fmt(_ format: String, _ args: CVarArg...) -> String { String(format: format, arguments: args) }

func ipv4(_ iface: String) -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return nil }
    defer { freeifaddrs(head) }
    var p = head
    while let ifa = p {
        defer { p = ifa.pointee.ifa_next }
        guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              String(cString: ifa.pointee.ifa_name) == iface else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            return String(cString: host)
        }
    }
    return nil
}

/// Same three buckets as vm_stat: active + wired + compressed.
func memoryUsedBytes(pageSize: Int) -> Int {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return (Int(stats.active_count) + Int(stats.wire_count) + Int(stats.compressor_page_count)) * pageSize
}

/// APFS container size and space in use by all its volumes (what `diskutil apfs list` reports).
func diskUsage() -> (used: Int, total: Int) {
    for path in ["/System/Volumes/Data", "/"] {
        var s = statfs()
        if statfs(path, &s) == 0 {
            let bsize = Int(s.f_bsize)
            let total = Int(s.f_blocks) * bsize
            return (total - Int(s.f_bavail) * bsize, total)
        }
    }
    return (0, 0)
}

/// Mirrors `pmset -g batt`: "75% discharging".
func batteryDisplay() -> String {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
    for src in sources {
        guard let desc = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
              desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let cur = desc[kIOPSCurrentCapacityKey] as? Int,
              let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        let pct = Int((Double(cur) / Double(max) * 100).rounded())
        let state: String
        if desc[kIOPSIsChargingKey] as? Bool == true { state = "charging" }
        else if desc[kIOPSIsFinishingChargeKey] as? Bool == true { state = "finishing charge" }
        else if desc[kIOPSIsChargedKey] as? Bool == true { state = "charged" }
        else if desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue { state = "AC attached" }
        else { state = "discharging" }
        return "\(pct)% \(state)"
    }
    return "N/A"
}

/// `brew list` = installed formulae + casks; count the directories instead of booting Ruby.
func brewCount() -> String {
    let path = env("PATH") ?? ""
    let fm = FileManager.default
    for dir in path.split(separator: ":") where fm.isExecutableFile(atPath: "\(dir)/brew") {
        let prefix = (String(dir) as NSString).deletingLastPathComponent
        let n = ["Cellar", "Caskroom"].reduce(0) { acc, sub in
            acc + ((try? fm.contentsOfDirectory(atPath: "\(prefix)/\(sub)"))?.filter { !$0.hasPrefix(".") }.count ?? 0)
        }
        return String(n)
    }
    return ""
}

// MARK: - Slow-but-static values (cached)
//
// Display resolution needs a WindowServer round-trip (~35 ms) and the shell version
// needs a fork+exec, so both are read from a cache and refreshed by a detached child.

let cacheFile: String = {
    let base = env("XDG_CACHE_HOME") ?? "\(NSHomeDirectory())/.cache"
    return "\(base)/machine-report/static"
}()

func displayResolution() -> String {
    let display = CGMainDisplayID()
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode], !modes.isEmpty else { return "" }
    let native = modes.first { $0.ioFlags & UInt32(kDisplayModeNativeFlag) != 0 }
        ?? modes.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }!
    let retina = modes.contains { $0.pixelWidth == native.pixelWidth && $0.width * 2 == $0.pixelWidth }
    return "\(native.pixelWidth) x \(native.pixelHeight)\(retina ? " Retina" : "")"
}

func shellVersion(_ shell: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: shell)
    p.arguments = ["--version"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    guard (try? p.run()) != nil else { return "" }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    let first = out.split(separator: "\n").first.map(String.init) ?? ""
    guard let r = first.range(of: "[0-9][0-9.]*", options: .regularExpression) else { return "" }
    return String(first[r])
}

func computeStatic(shell: String) -> [String: String] {
    ["shell_path": shell, "shell_version": shellVersion(shell), "display": displayResolution()]
}

func writeStatic(_ values: [String: String]) {
    let dir = (cacheFile as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let body = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
    try? body.write(toFile: cacheFile, atomically: true, encoding: .utf8)
}

func readStatic() -> [String: String]? {
    guard let text = try? String(contentsOfFile: cacheFile, encoding: .utf8) else { return nil }
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let eq = line.firstIndex(of: "=") else { continue }
        out[String(line[..<eq])] = String(line[line.index(after: eq)...])
    }
    return out
}

/// Fire-and-forget `machine-report --refresh-cache` in its own session, stdio on /dev/null.
func spawnRefresh() {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
        posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
    }
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), strdup("--refresh-cache"), nil]
    var pid: pid_t = 0
    posix_spawn(&pid, exe, &actions, &attr, argv, environ)
    argv.forEach { free($0) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
}

let shellPath = env("SHELL") ?? "/bin/zsh"

if CommandLine.arguments.contains("--refresh-cache") {
    writeStatic(computeStatic(shell: shellPath))
    exit(0)
}

var staticInfo: [String: String]
if !demoMode, let cached = readStatic(), cached["shell_path"] == shellPath {
    staticInfo = cached
    // Refresh at most once a minute, so a burst of new panes spawns one refresher.
    var st = stat()
    if stat(cacheFile, &st) != 0 || time(nil) - st.st_mtimespec.tv_sec > 60 { spawnRefresh() }
} else if !demoMode {
    staticInfo = computeStatic(shell: shellPath)
    writeStatic(staticInfo)
} else {
    staticInfo = [:]
}

// MARK: - Data gathering

// OS
var uts = utsname()
uname(&uts)
let machine = withUnsafeBytes(of: &uts.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
var osName = "macOS \(sysctlString("kern.osproductversion") ?? "") (\(machine))"
var osKernel = "Darwin \(sysctlString("kern.osrelease") ?? "")"
var osModel = sysctlString("hw.model") ?? ""

// Network
// gethostname, not ProcessInfo.hostName (which can block on a DNS lookup)
var hostBuf = [CChar](repeating: 0, count: 256)
gethostname(&hostBuf, hostBuf.count)
var netHostname = String(cString: hostBuf)
var netCurrentUser = getpwuid(geteuid()).map { String(cString: $0.pointee.pw_name) } ?? NSUserName()
var netMachineIP = ipv4("en0") ?? ipv4("en1") ?? "No IP"

// CPU
var cpuChip = sysctlString("machdep.cpu.brand_string") ?? ""
var cpuCores = sysctlInt("hw.ncpu") ?? 0
let cpuPcores = sysctlInt("hw.perflevel0.physicalcpu").map(String.init) ?? "?"
let cpuEcores = sysctlInt("hw.perflevel1.physicalcpu").map(String.init) ?? "?"
var cpuCoreInfo = "\(cpuPcores)P + \(cpuEcores)E / \(cpuCores) Threads"

// Load (rounded to 2 places, as `sysctl vm.loadavg` prints them)
var loads = [Double](repeating: 0, count: 3)
getloadavg(&loads, 3)
loads = loads.map { Double(fmt("%.2f", $0))! }

// Memory
let pageSize = sysctlInt("hw.pagesize") ?? Int(vm_kernel_page_size)
var memTotalBytes = sysctlInt("hw.memsize") ?? 0
var memUsedBytes = memoryUsedBytes(pageSize: pageSize)
let GiB = 1024.0 * 1024.0 * 1024.0
var memTotalGB = fmt("%.1f", Double(memTotalBytes) / GiB)
var memUsedGB = fmt("%.1f", Double(memUsedBytes) / GiB)
var memPercent = fmt("%.0f", memTotalBytes > 0 ? Double(memUsedBytes) / Double(memTotalBytes) * 100 : 0)

// Disk
let disk = diskUsage()
var rootTotalGB = fmt("%.0f", Double(disk.total) / GiB)
var rootUsedGB = fmt("%.0f", Double(disk.used) / GiB)
var diskPercent = fmt("%.0f", disk.total > 0 ? Double(disk.used) / Double(disk.total) * 100 : 0)
var rootUsed = disk.used / 1_048_576
var rootTotal = disk.total / 1_048_576

// Battery, display, shell, terminal, packages
var batteryDisplayText = batteryDisplay()
var displayRes = staticInfo["display"] ?? ""
var shellInfo = "\((shellPath as NSString).lastPathComponent) \(staticInfo["shell_version"] ?? "")"
var terminalInfo = "\(env("TERM_PROGRAM") ?? "Unknown") \(env("TERM_PROGRAM_VERSION") ?? "")"
var brewCountText = brewCount()

// Uptime
var boottime = timeval()
var btSize = MemoryLayout<timeval>.size
sysctlbyname("kern.boottime", &boottime, &btSize, nil, 0)
let uptimeSecs = Int(time(nil)) - boottime.tv_sec
let (days, hours, mins) = (uptimeSecs / 86400, (uptimeSecs % 86400) / 3600, (uptimeSecs % 3600) / 60)
var sysUptime = (days > 0 ? "\(days)d " : "") + (hours > 0 ? "\(hours)h " : "") + "\(mins)m"

// Demo mode overrides
if demoMode {
    osName = "macOS 15.3.1 (arm64)"
    osKernel = "Darwin 24.3.0"
    osModel = "Mac14,6"
    netHostname = "workstation.local"
    netMachineIP = "127.0.0.1"
    netCurrentUser = "user"
    cpuChip = "Apple M2 Max"
    cpuCores = 12
    cpuCoreInfo = "8P + 4E / 12 Threads"
    loads = [2.45, 1.87, 1.32]
    memTotalBytes = 32 * 1024 * 1024 * 1024
    memUsedBytes = 18 * 1024 * 1024 * 1024
    memTotalGB = "32.0"
    memUsedGB = "18.4"
    memPercent = "58"
    rootTotal = 953862
    rootUsed = 476931
    rootTotalGB = "932"
    rootUsedGB = "466"
    diskPercent = "50"
    batteryDisplayText = "78% discharging"
    displayRes = "3456 x 2234 Retina"
    shellInfo = "zsh 5.9"
    terminalInfo = "Apple_Terminal 453"
    brewCountText = "347"
    sysUptime = "4d 7h 23m"
}

let volumeText = "\(rootUsedGB)/\(rootTotalGB) GB [\(diskPercent)%]"
let memoryText = "\(memUsedGB)/\(memTotalGB) GiB [\(memPercent)%]"

let CURRENT_LEN = min(MAX_DATA_LEN, [
    reportTitle, osName, osKernel, osModel, netHostname, netMachineIP, netCurrentUser,
    cpuChip, cpuCoreInfo, volumeText, memoryText, batteryDisplayText, displayRes,
    shellInfo, terminalInfo, sysUptime,
].map(\.count).max()!)

// MARK: - Output

var out = ""

func rep(_ s: String, _ n: Int) -> String { n > 0 ? String(repeating: s, count: n) : "" }

func barGraph(_ used: Double, _ total: Double) -> String {
    let percent = total == 0 ? 0 : Double(fmt("%.2f", used / total * 100))!
    let blocks = min(CURRENT_LEN, Int(percent / 100 * Double(CURRENT_LEN)))
    return FG_BAR + rep("█", blocks) + FG_BAR_EMPTY + rep("░", CURRENT_LEN - blocks)
}

let shadowR = C_RESET + C_SHADOW + "  " + C_RESET

func printTop() {
    let inner = MAX_NAME_LEN + CURRENT_LEN + 5
    let colPos = MAX_NAME_LEN + 2
    let title = " \(reportTitle) "
    let eq = inner - title.count
    let el = eq / 2, er = eq - el
    let titleEnd = el + title.count
    let t = FG_TITLE + title + BG_WIN + FG_FRAME
    out += INDENT + BG_WIN + FG_FRAME + "╔"
    if colPos < el {
        out += rep("═", colPos) + "╤" + rep("═", el - colPos - 1) + t + rep("═", er)
    } else if colPos >= titleEnd {
        out += rep("═", el) + t + rep("═", colPos - titleEnd) + "╤" + rep("═", inner - colPos - 1)
    } else {
        out += rep("═", el) + t + rep("═", er)
    }
    out += "╗" + C_RESET + "\n"
}

func printBottom() {
    let inner = MAX_NAME_LEN + CURRENT_LEN + 5
    let colPos = MAX_NAME_LEN + 2
    out += INDENT + BG_WIN + FG_FRAME + "╚" + rep("═", colPos) + "╧" + rep("═", inner - colPos - 1)
    out += "╝" + C_RESET + shadowR + "\n"
    out += INDENT + "  " + C_SHADOW + rep(" ", inner + 2) + C_RESET + "\n"
}

func printDivider() {
    out += INDENT + BG_WIN + FG_FRAME + "╟" + FG_DIV + rep("─", MAX_NAME_LEN + 2) + "┼" + rep("─", CURRENT_LEN + 2)
    out += FG_FRAME + "╢" + C_RESET + shadowR + "\n"
}

func wrapText(_ text: String, _ width: Int) -> [String] {
    var lines: [String] = []
    var line = ""
    for word in text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
        var w = Substring(word)
        if w.count > width {
            if !line.isEmpty { lines.append(line); line = "" }
            while w.count > width {
                lines.append(String(w.prefix(width)))
                w = w.dropFirst(width)
            }
            line = String(w)
        } else if line.isEmpty {
            line = String(w)
        } else if line.count + 1 + w.count <= width {
            line += " " + w
        } else {
            lines.append(line)
            line = String(w)
        }
    }
    if !line.isEmpty { lines.append(line) }
    return lines.isEmpty ? [""] : lines
}

/// Drops SGR sequences (ESC [ … m).
func stripANSI(_ s: String) -> String {
    var result = ""
    var inEscape = false
    for c in s {
        if inEscape { if c == "m" { inEscape = false } }
        else if c == "\u{1B}" { inEscape = true }
        else { result.append(c) }
    }
    return result
}

func printData(_ rawName: String, _ data: String) {
    let truncated = rawName.count > MAX_NAME_LEN ? String(rawName.prefix(MAX_NAME_LEN - 3)) + "..." : rawName
    let name = truncated + rep(" ", MAX_NAME_LEN - truncated.count)
    let blankName = rep(" ", MAX_NAME_LEN)
    let stripped = stripANSI(data)
    let vis = stripped.count
    let lines = vis > CURRENT_LEN ? wrapText(stripped, CURRENT_LEN) : [data]
    for (idx, line) in lines.enumerated() {
        let padVis = (idx == 0 && vis <= CURRENT_LEN) ? vis : line.count
        let label = FG_LABEL + (idx == 0 ? name : blankName)
        out += INDENT + BG_WIN + FG_FRAME + "║ " + label + " " + FG_DIV + "│" + C_RESET + BG_WIN + " "
        out += FG_TEXT + line + rep(" ", CURRENT_LEN - padVis) + " " + FG_FRAME + "║" + C_RESET + shadowR + "\n"
    }
}

let cores = Double(cpuCores)

out += "\n"
printTop()
printData("MODEL", osModel)
printData("OS", osName)
printData("KERNEL", osKernel)
printDivider()
printData("HOST", netHostname)
printData("IP", netMachineIP)
printData("USER", netCurrentUser)
printDivider()
printData("CHIP", cpuChip)
printData("CORES", cpuCoreInfo)
printData("LOAD  1m", barGraph(loads[0], cores))
printData("LOAD  5m", barGraph(loads[1], cores))
printData("LOAD 15m", barGraph(loads[2], cores))
printDivider()
printData("VOLUME", volumeText)
printData("DISK USAGE", barGraph(Double(rootUsed), Double(rootTotal)))
printDivider()
printData("MEMORY", memoryText)
printData("USAGE", barGraph(Double(memUsedBytes), Double(memTotalBytes)))
printDivider()
printData("BATTERY", batteryDisplayText)
printData("DISPLAY", displayRes)
printData("SHELL", shellInfo)
printData("TERMINAL", terminalInfo)
if !brewCountText.isEmpty { printData("PACKAGES", "\(brewCountText) (brew)") }
printData("UPTIME", sysUptime)
printBottom()
out += "\n"

FileHandle.standardOutput.write(out.data(using: .utf8)!)
