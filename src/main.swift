import AppKit
import CoreGraphics

private let PMSET = "/usr/bin/pmset"
private let IOREG = "/usr/sbin/ioreg"
private let SUDO = "/usr/bin/sudo"

private let kFloorOn = "guard.battery.on"
private let kFloorValue = "guard.battery.value"
private let kLowPowerOn = "guard.lowpower.on"
private let kLidOpenOn = "guard.lidopen.on"
private let kTimerSeconds = "guard.timer.seconds"
private let kBlankOnClose = "opt.blankonclose"

/// 菜单里表示选中状态的文字标记。故意不用 NSMenuItem.state：
/// 带 submenu 的父项如果 action 为空就不会画出勾选，只有标题里的字符一定画得出来。
private let onMark = "✓ "
private let offMark = ""

private func sh(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// pmset -g 的字段分隔符是制表符（SleepDisabled\t\t1），
/// 也有用空格对齐的行（lowpowermode         0），所以必须按任意空白切分。
private func parseG(_ text: String) -> (sleepDisabled: Bool, lowPowerMode: Bool, ok: Bool) {
    var disabled = false
    var low = false
    var ok = false
    for line in text.split(separator: "\n") {
        let f = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard f.count >= 2 else { continue }
        switch f[0] {
        case "SleepDisabled":
            disabled = f[1] == "1"
            ok = true
        case "lowpowermode":
            low = f[1] == "1"
            ok = true
        default:
            break
        }
    }
    return (disabled, low, ok)
}

private struct Snapshot {
    var sleepDisabled = false
    var lowPowerMode = false
    var onAC = true
    var battery = 100
    var lidClosed = false
    var displays = 0
    /// 在线列表里除内建屏以外的显示器。有它就说明处在 clamshell 模式，不能去灭屏。
    var externalDisplayOnline = false
    /// 内建屏在线且没睡 —— 也就是"屏还亮着"。休眠中的显示器仍在在线列表里，靠 asleep 区分。
    var builtinAwake = false
    /// pmset -g 是否读到了可用字段。读不到时不做任何自动判断，避免把读取失败当成状态变化。
    var ok = false
}

private func takeSnapshot() -> Snapshot {
    var s = Snapshot()
    let g = parseG(sh(PMSET, ["-g"]).out)
    s.sleepDisabled = g.sleepDisabled
    s.lowPowerMode = g.lowPowerMode
    s.ok = g.ok

    let batt = sh(PMSET, ["-g", "batt"]).out
    s.onAC = batt.contains("'AC Power'")
    if let r = batt.range(of: "[0-9]+%", options: .regularExpression) {
        s.battery = Int(batt[r].dropLast()) ?? 100
    }

    s.lidClosed = sh(IOREG, ["-r", "-k", "AppleClamshellState", "-d", "4"])
        .out.contains("\"AppleClamshellState\" = Yes")

    var n: UInt32 = 0
    _ = CGGetOnlineDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(n, 1)))
    var real: UInt32 = 0
    _ = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &real)
    s.displays = Int(real)
    for i in 0..<Int(real) {
        let id = ids[i]
        if CGDisplayIsBuiltin(id) != 0 {
            if CGDisplayIsAsleep(id) == 0 { s.builtinAwake = true }
        } else {
            s.externalDisplayOnline = true
        }
    }
    return s
}

/// 合盖后是否该主动熄屏。抽成纯函数，好让 --check 用合成数据覆盖整张真值表。
private func shouldBlank(_ s: Snapshot, enabled: Bool) -> Bool {
    enabled && s.lidClosed && !s.externalDisplayOnline && s.builtinAwake
}

private final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let durations: [(String, Int)] = [
        ("不限", 0), ("30 分钟", 1800), ("1 小时", 3600), ("2 小时", 7200), ("4 小时", 14400),
    ]

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let d = UserDefaults.standard

    /// 界面的真值来源：我们最后一次成功设置成什么。系统值只用来发现"被别人改回"。
    private var armed = false
    private var snapshot = Snapshot()
    private var deadline: Date?
    private var lowPowerAtArm = false
    private var notice: (text: String, alarming: Bool)?
    private var poll: Timer?

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        d.register(defaults: [
            kFloorOn: true, kFloorValue: 20, kLowPowerOn: true, kLidOpenOn: false, kTimerSeconds: 0,
            kBlankOnClose: true,
        ])
        menu.delegate = self
        item.menu = menu
        refresh()

        // 上次异常退出可能把系统标志留在 1：启动只负责复位，绝不自动打开
        if snapshot.sleepDisabled {
            notice = setFlag(false).map { ("系统里残留着保活标志，但复位失败：\($0)", true) }
                ?? ("检测到上次遗留的保活标志，已复位", false)
            refresh()
        }
    }

    // MARK: - 系统读写

    private func setFlag(_ on: Bool) -> String? {
        let r = sh(SUDO, ["-n", PMSET, "-a", "disablesleep", on ? "1" : "0"])
        guard r.status != 0 else { return nil }
        let msg = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? "退出码 \(r.status)" : msg
    }

    // MARK: - 界面

    private func refresh(_ snap: Snapshot? = nil) {
        snapshot = snap ?? takeSnapshot()
        updateIcon()
    }

    private func updateIcon() {
        let symbol: String
        if armed {
            symbol = "moon.zzz.fill"
        } else if let n = notice, n.alarming {
            symbol = "exclamationmark.triangle"
        } else {
            symbol = "moon.zzz"
        }
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "不许睡") {
            img.isTemplate = true
            item.button?.image = img
        }
        item.button?.toolTip = tooltip()
    }

    private func tooltip() -> String {
        if armed {
            var t = "不许睡：已开启"
            if let dl = deadline { t += " · 剩 \(minutesLeft(dl)) 分钟" }
            return t
        }
        if let n = notice { return "不许睡：已松开（\(n.text)）" }
        return "不许睡：已关闭"
    }

    private func minutesLeft(_ dl: Date) -> Int {
        max(0, Int(dl.timeIntervalSinceNow / 60))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        menu.addItem(plain("不许睡"))
        menu.addItem(plain(armed
            ? "状态：已开启 —— 合盖 / 显示器关闭都继续运行"
            : "状态：正常，系统按原设置睡眠"))
        menu.addItem(mk(mark(armed) + "不许睡（合盖 / 显示器关闭都继续运行）", #selector(toggleMaster)))
        if let n = notice, !armed {
            menu.addItem(plain("    上次状态：\(n.text)"))
        }

        menu.addItem(mk(mark(d.bool(forKey: kBlankOnClose)) + "合盖后熄灭内建屏幕",
                        #selector(toggleBlankOnClose)))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(plain("安全阀（满足条件时自动松开）"))

        let floorItem = mk(mark(d.bool(forKey: kFloorOn))
            + "电池低于 \(d.integer(forKey: kFloorValue))% 自动松开")
        floorItem.submenu = batteryMenu()
        menu.addItem(floorItem)

        let secs = d.integer(forKey: kTimerSeconds)
        let timerItem = mk(mark(secs > 0) + timerTitle(secs))
        timerItem.submenu = timerMenu()
        menu.addItem(timerItem)

        menu.addItem(mk(mark(d.bool(forKey: kLowPowerOn)) + "低电量模式时自动松开",
                        #selector(toggleLowPower)))
        menu.addItem(mk(mark(d.bool(forKey: kLidOpenOn)) + "盖子打开后自动松开",
                        #selector(toggleLidOpen)))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(plain("电源：\(snapshot.onAC ? "适配器供电" : "电池供电") · 电量 \(snapshot.battery)%"))
        menu.addItem(plain("盖子：\(snapshot.lidClosed ? "已合上" : "已打开") · 在线显示器 \(snapshot.displays) 台"
            + (snapshot.externalDisplayOnline ? "（含外接屏）" : "")))
        menu.addItem(plain("内建屏：\(snapshot.builtinAwake ? "亮着" : "已熄灭")"))
        if snapshot.lidClosed && snapshot.displays == 0 {
            menu.addItem(plain("    注意：合盖且零显示器，系统可能因显示器丢失而睡眠"))
        }
        if !snapshot.ok {
            menu.addItem(plain("    警告：读不到系统电源设置，自动判断已暂停"))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(mk(armed ? "松开并退出" : "退出", #selector(quit)))
    }

    private func mark(_ on: Bool) -> String {
        on ? onMark : offMark
    }

    private func timerTitle(_ secs: Int) -> String {
        guard secs > 0 else { return "计时器：不限" }
        let label = Self.durations.first { $0.1 == secs }?.0 ?? "\(secs) 秒"
        guard let dl = deadline else { return "计时器：\(label)" }
        return "计时器：\(label)（剩 \(minutesLeft(dl)) 分）"
    }

    private func batteryMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(mk(mark(d.bool(forKey: kFloorOn)) + "启用", #selector(toggleFloor)))
        m.addItem(NSMenuItem.separator())
        for v in [10, 15, 20, 30, 50] {
            let i = mk(mark(d.integer(forKey: kFloorValue) == v) + "阈值 \(v)%", #selector(setFloor(_:)))
            i.representedObject = v
            m.addItem(i)
        }
        return m
    }

    private func timerMenu() -> NSMenu {
        let m = NSMenu()
        for (label, secs) in Self.durations {
            let i = mk(mark(d.integer(forKey: kTimerSeconds) == secs) + label, #selector(setTimer(_:)))
            i.representedObject = secs
            m.addItem(i)
        }
        return m
    }

    private func mk(_ title: String, _ sel: Selector? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    private func plain(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: - 开关

    @objc private func toggleMaster() {
        if armed {
            _ = setFlag(false)
            armed = false
            deadline = nil
            notice = nil
            stopPolling()
            refresh()
        } else {
            arm()
        }
    }

    private func arm() {
        if let err = setFlag(true) {
            alert(err)
            return
        }
        armed = true
        lowPowerAtArm = snapshot.lowPowerMode
        let secs = d.integer(forKey: kTimerSeconds)
        deadline = secs > 0 ? Date().addingTimeInterval(Double(secs)) : nil
        notice = nil
        startPolling()
        refresh()
        // 刚设完不判漂移：只跑一次安全阀，免得读取没跟上被当成"被改回"
        evaluate(drift: false)
    }

    private func release(_ reason: String, alarming: Bool) {
        _ = setFlag(false)
        armed = false
        deadline = nil
        notice = (reason, alarming)
        stopPolling()
        refresh()
    }

    @objc private func quit() {
        if armed { _ = setFlag(false) }
        NSApp.terminate(nil)
    }

    // MARK: - 安全阀

    private func startPolling() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    private func evaluate(drift: Bool = true) {
        guard armed else { return }
        let s = takeSnapshot()
        // 读不到系统状态就什么都不判，免得把偶发的读取失败当成"被改回"
        guard s.ok else { return }

        // 已被其它程序改回：先把系统侧真正关掉，界面和现实一致后再改界面
        if drift && !s.sleepDisabled {
            _ = setFlag(false)
            armed = false
            deadline = nil
            notice = ("保活标志被系统或其它程序改回，已停止", true)
            stopPolling()
            refresh(s)
            return
        }

        if d.bool(forKey: kFloorOn), !s.onAC {
            let floor = d.integer(forKey: kFloorValue)
            if s.battery <= floor {
                release("电量 \(s.battery)% 已到下限 \(floor)%", alarming: true)
                return
            }
        }
        if d.bool(forKey: kLowPowerOn), s.lowPowerMode, !lowPowerAtArm {
            release("系统进入了低电量模式", alarming: true)
            return
        }
        if d.bool(forKey: kLidOpenOn), !s.lidClosed {
            release("盖子已打开", alarming: false)
            return
        }
        if let dl = deadline, Date() >= dl {
            release("计时器到时", alarming: false)
            return
        }
        // 补上被 disablesleep 一起挡掉的"灭屏"这一步。只在没有外接屏时才动手：
        // 有外接屏说明你在用 clamshell 模式，那是工作屏，不能灭。
        if shouldBlank(s, enabled: d.bool(forKey: kBlankOnClose)) {
            _ = sh(PMSET, ["displaysleepnow"])
        }
        refresh(s)
    }

    @objc private func toggleFloor() {
        d.set(!d.bool(forKey: kFloorOn), forKey: kFloorOn)
        refresh()
    }

    @objc private func setFloor(_ sender: NSMenuItem) {
        d.set(sender.representedObject as? Int ?? 20, forKey: kFloorValue)
        refresh()
    }

    @objc private func toggleLowPower() {
        d.set(!d.bool(forKey: kLowPowerOn), forKey: kLowPowerOn)
        refresh()
    }

    @objc private func toggleLidOpen() {
        d.set(!d.bool(forKey: kLidOpenOn), forKey: kLidOpenOn)
        refresh()
    }

    @objc private func toggleBlankOnClose() {
        d.set(!d.bool(forKey: kBlankOnClose), forKey: kBlankOnClose)
        refresh()
    }

    @objc private func setTimer(_ sender: NSMenuItem) {
        let secs = sender.representedObject as? Int ?? 0
        d.set(secs, forKey: kTimerSeconds)
        if armed {
            deadline = secs > 0 ? Date().addingTimeInterval(Double(secs)) : nil
        }
        refresh()
    }

    // MARK: - 授权失败

    private func alert(_ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "没有拿到免密授权"
        a.informativeText = "改这个开关需要 root 权限。请在项目目录里运行一次 ./install.sh 完成授权。\n\n系统返回：\(detail)"
        a.addButton(withTitle: "好")
        a.runModal()
    }
}

// 自检：解析回归 + 打印实时状态，都不修改系统
if CommandLine.arguments.contains("--check") {
    let cases: [(String, Bool)] = [
        (" SleepDisabled\t\t1", true),
        (" SleepDisabled\t\t0", false),
        (" SleepDisabled         1", true),
        (" SleepDisabled\t\t0\n lowpowermode         0", false),
    ]
    var passed = 0
    for (text, want) in cases where parseG(text).sleepDisabled == want { passed += 1 }
    print("解析自检: \(passed == cases.count ? "PASS" : "FAIL \(passed)/\(cases.count)")")

    let s = takeSnapshot()
    print("实时状态: SleepDisabled=\(s.sleepDisabled ? 1 : 0) lowPowerMode=\(s.lowPowerMode ? 1 : 0) "
        + "onAC=\(s.onAC ? 1 : 0) battery=\(s.battery) lidClosed=\(s.lidClosed ? 1 : 0) "
        + "displays=\(s.displays) external=\(s.externalDisplayOnline ? 1 : 0) "
        + "builtinAwake=\(s.builtinAwake ? 1 : 0) ok=\(s.ok ? 1 : 0)")

    // 熄屏判定的真值表：只有"开着选项 + 合盖 + 无外接屏 + 内建屏亮着"才动手
    func snap(_ lid: Bool, _ ext: Bool, _ awake: Bool) -> Snapshot {
        var s = Snapshot()
        s.lidClosed = lid
        s.externalDisplayOnline = ext
        s.builtinAwake = awake
        return s
    }
    let blankCases: [(String, Snapshot, Bool, Bool)] = [
        ("合盖·无外接·屏亮·选项开", snap(true, false, true), true, true),
        ("合盖·无外接·屏已灭·选项开", snap(true, false, false), true, false),
        ("合盖·有外接·选项开", snap(true, true, true), true, false),
        ("开盖·选项开", snap(false, false, true), true, false),
        ("合盖·无外接·屏亮·选项关", snap(true, false, true), false, false),
    ]
    var blankPassed = blankCases.count
    let blankFailed = blankCases.filter { shouldBlank($0.1, enabled: $0.2) != $0.3 }.map { $0.0 }
    blankPassed -= blankFailed.count
    print("熄屏判定自检: \(blankFailed.isEmpty ? "PASS" : "FAIL \(blankFailed)")")
    exit(0)
}

let app = NSApplication.shared
private let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
