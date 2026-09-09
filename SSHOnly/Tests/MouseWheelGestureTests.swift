import Foundation

@main
enum MouseWheelGestureTests {
  static func main() {
    precondition(MouseWheelGesture.eventCount(for: 23, pointsPerEvent: 24) == 0)
    precondition(MouseWheelGesture.eventCount(for: 24, pointsPerEvent: 24) == 1)
    precondition(MouseWheelGesture.eventCount(for: 53, pointsPerEvent: 24) == 2)
    precondition(MouseWheelGesture.eventCount(for: -53, pointsPerEvent: 24) == -2)
    precondition(MouseWheelGesture.eventCount(for: 0, pointsPerEvent: 24) == 0)
    precondition(MouseWheelGesture.button(for: -1) == 5)
    precondition(MouseWheelGesture.button(for: 1) == 4)
    print("MouseWheelGestureTests passed")
  }
}
