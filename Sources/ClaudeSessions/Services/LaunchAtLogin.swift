import Foundation
import ServiceManagement

enum LaunchAtLogin {
    private static let autoRegisterKey = "didAutoRegisterLaunchAtLogin"

    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[ClaudeSessions] LaunchAtLogin error: \(error)")
            }
        }
    }

    static func registerOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: autoRegisterKey) else { return }
        defaults.set(true, forKey: autoRegisterKey)
        isEnabled = true
    }
}
