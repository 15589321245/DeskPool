import AppKit
import Network

enum RoomDiscovery {
    static func chooseRoom() -> NWEndpoint? {
        let browser = NWBrowser(for: .bonjour(type: "_dibilliards._tcp", domain: nil), using: .tcp)
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 66, width: 310, height: 28))
        popup.addItem(withTitle: "正在搜索局域网房间…")
        let manual = NSTextField(frame: NSRect(x: 0, y: 8, width: 310, height: 24))
        manual.placeholderString = "或输入房主 IP，例如 192.168.1.23"
        let label = NSTextField(labelWithString: "搜索不到时可直接输入房主 IP：")
        label.frame = NSRect(x: 0, y: 38, width: 310, height: 18)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 98))
        accessory.addSubview(popup)
        accessory.addSubview(label)
        accessory.addSubview(manual)
        var endpoints: [NWEndpoint] = []
        browser.browseResultsChangedHandler = { results, _ in
            let rooms = results.compactMap { result -> (String, NWEndpoint)? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return (name, result.endpoint)
            }.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            DispatchQueue.main.async {
                endpoints = rooms.map(\.1)
                popup.removeAllItems()
                if rooms.isEmpty { popup.addItem(withTitle: "未发现房间，请确认房主已启动") }
                else { popup.addItems(withTitles: rooms.map(\.0)) }
            }
        }
        let alert = NSAlert()
        alert.messageText = "加入局域网房间"
        alert.informativeText = "选择房主的电脑；请确保连接同一局域网。"
        alert.accessoryView = accessory
        alert.addButton(withTitle: "加入")
        alert.addButton(withTitle: "取消")
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed, .waiting:
                DispatchQueue.main.async {
                    alert.informativeText = "搜索受网络或系统权限限制，请检查本地网络权限，或直接输入房主 IP。"
                }
            default: break
            }
        }
        browser.start(queue: DispatchQueue(label: "DesktopIconBilliards.Discovery"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if endpoints.isEmpty && popup.titleOfSelectedItem == "正在搜索局域网房间…" {
                popup.removeAllItems()
                popup.addItem(withTitle: "未发现房间，请确认房主已启动")
                alert.informativeText = "确认双方在同一局域网且房主使用新版；也可以输入房主 IP。"
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        while true {
            let result = alert.runModal()
            if result != .alertFirstButtonReturn { browser.cancel(); return nil }
            let host = manual.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !host.isEmpty {
                browser.cancel()
                return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 7777)!)
            }
            if endpoints.indices.contains(popup.indexOfSelectedItem) {
                let endpoint = endpoints[popup.indexOfSelectedItem]
                browser.cancel()
                return endpoint
            }
            alert.informativeText = "尚未发现房间。请继续等待，或输入房主的 IP 地址。"
        }
    }
}
