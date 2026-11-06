// MoonRiseBar — 菜单栏 App 入口。生命周期即进程：App 在则屏在。

import AppKit

let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.accessory)
application.run()
