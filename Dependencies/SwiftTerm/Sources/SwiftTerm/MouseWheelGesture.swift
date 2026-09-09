import Foundation

public enum MouseWheelGesture {
  public static func eventCount(for translation: CGFloat, pointsPerEvent: CGFloat) -> Int {
    guard pointsPerEvent > 0 else { return 0 }
    return Int(translation / pointsPerEvent)
  }

  public static func button(for events: Int) -> Int {
    events < 0 ? 5 : 4
  }
}
