import Foundation

@main
struct MicroJigglerPreferenceTests {
    static func main() throws {
        let suite = "overlook.microJiggler.fixture.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.unavailable }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        let store = MicroJigglerPreference.live(defaults: defaults)
        let first = MicroJigglerPreference.endpointKey(host: "KVM.fixture.invalid", port: 80)
        let second = MicroJigglerPreference.endpointKey(host: "kvm.fixture.invalid", port: 443)
        let other = MicroJigglerPreference.endpointKey(host: "other.fixture.invalid", port: 80)
        try expect(first == "kvm.fixture.invalid:80", "Endpoint key was unstable")
        try expect(store.read(first) == nil, "Missing preference acquired a default")
        store.write(true, first)
        store.write(false, second)
        let relaunched = MicroJigglerPreference.live(defaults: defaults)
        try expect(relaunched.read(first) == true && relaunched.read(second) == false,
                   "Boolean local intent did not survive a new boundary")
        try expect(relaunched.read(other) == nil, "Preference crossed host or port boundaries")
        store.write(false, first)
        try expect(store.read(first) == false, "Existing Boolean true did not accept local off")
        for invalid: Any in [1, 0, "true", "false", [true], ["active": true]] {
            // UserDefaults coalesces NSNumber(1) with an existing Boolean true.
            // Seed a genuinely new nonboolean record rather than testing that cache equality.
            defaults.removeObject(forKey: "overlook.microJiggler." + first)
            defaults.set(invalid, forKey: "overlook.microJiggler." + first)
            try expect(store.read(first) == nil, "Nonboolean value was accepted: \(type(of: invalid)) \(invalid)")
        }
        for (legacy, intended) in [(1, true), (0, false)] {
            defaults.removeObject(forKey: "overlook.microJiggler." + first)
            defaults.set(legacy, forKey: "overlook.microJiggler." + first)
            store.write(intended, first)
            try expect(store.read(first) == intended, "Writing Boolean intent retained a numeric legacy record")
        }
        try expect(MicroJigglerPreference.disabled.read(first) == nil, "Test default read persistent state")
        MicroJigglerPreference.disabled.write(true, first)
        try expect(MicroJigglerPreference.disabled.read(first) == nil, "Disabled boundary retained state")
        print("MicroJigglerPreferenceTests: missing, stable endpoint, strict booleans, relaunch and disabled boundary passed; isolated UUID suite only")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.message(message) }
    }
    private enum Failure: Error { case unavailable, message(String) }
}
