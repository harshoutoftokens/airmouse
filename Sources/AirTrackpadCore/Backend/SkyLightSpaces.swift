import Foundation
import CoreGraphics
import ColorSync

/// Snapshot of the Spaces on one display.
public struct SpaceInfo: Sendable, Equatable {
    public var currentIndex: Int
    public var count: Int
    public var displayIdentifier: String

    public init(currentIndex: Int, count: Int, displayIdentifier: String) {
        self.currentIndex = currentIndex
        self.count = count
        self.displayIdentifier = displayIdentifier
    }

    public func canMove(_ direction: SwipeDirection) -> Bool {
        switch direction {
        case .left: return currentIndex > 0
        case .right: return currentIndex + 1 < count
        default: return false
        }
    }
}

/// Read-only access to the window server's Space list.
///
/// Uses the private CoreGraphics/SkyLight calls that window managers rely on
/// (`CGSCopyManagedDisplaySpaces`, as used by InstantSpaceSwitcher, Mac Mouse Fix, yabai).
/// They're resolved at runtime with `dlsym`, so a future macOS that removes them degrades to
/// "unknown" instead of crashing.
public enum SkyLightSpaces {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32, CFString?) -> Unmanaged<CFArray>?

    /// RTLD_DEFAULT: search every image already loaded into the process.
    private static func lookup(_ names: String...) -> UnsafeMutableRawPointer? {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        for name in names {
            if let sym = dlsym(handle, name) { return sym }
        }
        return nil
    }

    private static let mainConnection: MainConnectionFn? = {
        guard let sym = lookup("CGSMainConnectionID", "SLSMainConnectionID") else { return nil }
        return unsafeBitCast(sym, to: MainConnectionFn.self)
    }()

    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = {
        guard let sym = lookup("CGSCopyManagedDisplaySpaces", "SLSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(sym, to: CopyManagedDisplaySpacesFn.self)
    }()

    public static var isAvailable: Bool {
        mainConnection != nil && copyManagedDisplaySpaces != nil
    }

    /// Spaces of the display under `point` (the pointer), which is the display a dock swipe acts on.
    public static func spaceInfo(at point: CGPoint) -> SpaceInfo? {
        guard let mainConnection, let copyManagedDisplaySpaces else { return nil }
        let connection = mainConnection()
        guard connection != 0,
              let unmanaged = copyManagedDisplaySpaces(connection, nil) else { return nil }
        let displays = unmanaged.takeRetainedValue() as NSArray

        var targetUUID: String?
        var displayID: CGDirectDisplayID = 0
        var found: UInt32 = 0
        if CGGetDisplaysWithPoint(point, 1, &displayID, &found) == .success, found > 0,
           let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            targetUUID = CFUUIDCreateString(nil, uuid) as String?
        }

        var chosen: NSDictionary?
        for case let display as NSDictionary in displays {
            if chosen == nil { chosen = display }
            if let id = display["Display Identifier"] as? String,
               let targetUUID, id.caseInsensitiveCompare(targetUUID) == .orderedSame {
                chosen = display
                break
            }
        }
        guard let display = chosen,
              let spaces = display["Spaces"] as? [NSDictionary],
              !spaces.isEmpty else { return nil }

        let currentID = (display["Current Space"] as? NSDictionary)?["id64"] as? NSNumber
        let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard let currentID, let index = ids.firstIndex(of: currentID.uint64Value) else { return nil }
        return SpaceInfo(
            currentIndex: index,
            count: ids.count,
            displayIdentifier: display["Display Identifier"] as? String ?? "main"
        )
    }
}
