import Foundation

/// Samsung TVs do not report the foreground app over the local network. This tracks
/// what this Mac opened; a press on the physical remote can change the screen unseen.
struct TVActivity: Equatable {
    enum Focus: Equatable { case unknown, app(String), input(String) }
    private(set) var focus: Focus = .unknown
    private(set) var homeShown = false
    mutating func opened(_ focus: Focus) { self.focus = focus; homeShown = false }
    mutating func pressed(_ key: String) {
        switch key {
        case "KEY_HOME": homeShown = true
        // Back closes the Home bar and returns to whatever was underneath.
        case "KEY_RETURN": homeShown = false
        // Selecting a Home tile opens something this Mac cannot name.
        case "KEY_ENTER": if homeShown { reset() }
        case "KEY_EXIT":
            homeShown = false
            if case .app = focus { focus = .unknown }
        case "KEY_TV": opened(.input("TV"))
        case "KEY_POWER": reset()
        default: break
        }
    }
    mutating func reset() { focus = .unknown; homeShown = false }
}

/// Turns touchpad drags into arrow keys, one key per `step` points along the main axis,
/// or into pointer moves scaled by `gain` where the TV shows a pointer.
struct SwipePad {
    let step: Double
    let gain: Double
    private var x = 0.0
    private var y = 0.0
    private var pointerX = 0.0
    private var pointerY = 0.0
    init(step: Double = 34, gain: Double = 3) { self.step = step; self.gain = gain }
    /// Whole pointer units only; the fractions carry over to the next move.
    mutating func pointer(dx: Double, dy: Double) -> (x: Int, y: Int)? {
        pointerX += dx * gain; pointerY += dy * gain
        let moveX = Int(pointerX), moveY = Int(pointerY)
        guard moveX != 0 || moveY != 0 else { return nil }
        pointerX -= Double(moveX); pointerY -= Double(moveY)
        return (moveX, moveY)
    }
    mutating func drag(dx: Double, dy: Double) -> [String] {
        x += dx; y += dy
        var keys: [String] = []
        while abs(x) >= step || abs(y) >= step {
            if abs(x) >= abs(y) { keys.append(x > 0 ? "KEY_RIGHT" : "KEY_LEFT"); x -= x > 0 ? step : -step; y = 0 }
            else { keys.append(y > 0 ? "KEY_DOWN" : "KEY_UP"); y -= y > 0 ? step : -step; x = 0 }
        }
        return keys
    }
    mutating func end() { x = 0; y = 0; pointerX = 0; pointerY = 0 }
}
