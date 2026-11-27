import SwiftUI
import AppKit

@main
struct NetPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        SwiftUI.Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var store: NetPilotStore!
    private var statusUpdateTimer: Timer?

    private let widthKey = "NetPilotPopoverWidth"
    private let heightKey = "NetPilotPopoverHeight"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store = NetPilotStore()

        setupPopover()
        setupStatusItem()
        startStatusIconUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) { store.stop() }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
            updateStatusButton()
        }
    }

    private func setupPopover() {
        let savedW = UserDefaults.standard.double(forKey: widthKey)
        let initW = savedW >= 420 ? min(savedW, 680) : 440

        popover = NSPopover()
        popover.contentSize = NSSize(width: initW, height: 174)
        popover.behavior = .transient
        popover.animates = true

        let rootView = MenuBarContentView(
            store: store,
            onResize: { [weak self] dw, dh in
                self?.resizePopover(deltaWidth: dw, deltaHeight: dh)
            },
            onPinChange: { [weak self] pinned in
                self?.popover.behavior = pinned ? .applicationDefined : .transient
            },
            onLayoutChange: { [weak self] listExpanded, hotspotExpanded, hasMessage in
                self?.updatePopoverHeight(listExpanded: listExpanded, hotspotExpanded: hotspotExpanded, hasMessage: hasMessage)
            }
        )
        let controller = NSHostingController(rootView: rootView)
        controller.sizingOptions = []
        popover.contentViewController = controller
    }

    private func updatePopoverHeight(listExpanded: Bool, hotspotExpanded: Bool, hasMessage: Bool) {
        let curW = popover.contentSize.width
        let screenMaxH = (NSScreen.main?.visibleFrame.height ?? 900) - 60
        let msgExtra: CGFloat = hasMessage ? 22 : 0
        let targetH: CGFloat
        if listExpanded {
            let baseH: CGFloat = 490
            targetH = min(baseH + (hotspotExpanded ? 148 : 0) + msgExtra, screenMaxH)
        } else {
            targetH = (hotspotExpanded ? 324 : 174) + msgExtra
        }
        guard abs(popover.contentSize.height - targetH) > 0.5 else { return }
        let prevAnimates = popover.animates
        popover.animates = false
        popover.contentSize = NSSize(width: curW, height: targetH)
        popover.animates = prevAnimates
    }

    private func resizePopover(deltaWidth: CGFloat, deltaHeight: CGFloat) {
        let screenMaxH = (NSScreen.main?.visibleFrame.height ?? 900) - 40
        let cur = popover.contentSize
        let nextW = min(max(cur.width + deltaWidth, 420), 680)
        let nextH = min(max(cur.height + deltaHeight, 440), max(500, screenMaxH))
        popover.contentSize = NSSize(width: nextW, height: nextH)
        UserDefaults.standard.set(Double(nextW), forKey: widthKey)
        UserDefaults.standard.set(Double(nextH), forKey: heightKey)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown {
            togglePopover(nil)
        }
        return true
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.reloadAll(forceConfig: true)
            popover.behavior = store.isPinned ? .applicationDefined : .transient
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func startStatusIconUpdater() {
        statusUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusButton()
            }
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let hsActive = store.runtime?.hotspot.active ?? false

        // 任务栏大号单字母图标：P = 蓝色分流中，D = 单色直连/断开
        let sizeCfg = NSImage.SymbolConfiguration(pointSize: 16.5, weight: .bold)
        if hsActive {
            let colorCfg = NSImage.SymbolConfiguration(paletteColors: [.white, .systemBlue])
            if let img = NSImage(systemSymbolName: "p.square.fill", accessibilityDescription: "P 分流中")?
                .withSymbolConfiguration(sizeCfg.applying(colorCfg)) {
                img.isTemplate = false
                button.image = img
            }
        } else {
            if let img = NSImage(systemSymbolName: "d.square", accessibilityDescription: "D 直连")?
                .withSymbolConfiguration(sizeCfg) {
                img.isTemplate = true
                button.image = img
            }
        }
        button.title = ""
        button.toolTip = hsActive ? "NetPilot (P · 分流中)" : "NetPilot (D · 直连)"
    }
}
