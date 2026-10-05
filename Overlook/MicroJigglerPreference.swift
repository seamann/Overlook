import Foundation
import CoreFoundation

/// Local user intent is separate from the firmware's large movement loop.
struct MicroJigglerPreference {
    let read: (String) -> Bool?
    let write: (Bool, String) -> Void

    static let disabled = Self(read: { _ in nil }, write: { _, _ in })

    static func endpointKey(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    static func live(defaults: UserDefaults = .standard) -> Self {
        let prefix = "overlook.microJiggler."
        return Self(read: { deviceID in
            guard let value = defaults.object(forKey: prefix + deviceID) as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value.boolValue
        }, write: { enabled, deviceID in
            let key = prefix + deviceID
            if let existing = defaults.object(forKey: key) {
                // UserDefaults may coalesce numeric 1/0 with Boolean true/false.
                // Replace malformed legacy records so the new intent is strictly Boolean.
                if let number = existing as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    defaults.set(enabled, forKey: key)
                    return
                }
                defaults.removeObject(forKey: key)
            }
            defaults.set(enabled, forKey: key)
        })
    }
}
