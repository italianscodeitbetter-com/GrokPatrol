import Flutter
import UIKit

/// La barra in basso: un `UITabBar` di sistema, non un'imitazione. Da iOS 26 il Liquid Glass arriva da UIKit,
/// con la lente che segue il dito e la rifrazione di quello che ci scorre sotto, mappa 3D compresa.
final class GlassTabBarFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "grokpatrol/tab-bar"

  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    GlassTabBarView(frame: frame, viewId: viewId, args: args as? [String: Any] ?? [:], messenger: messenger)
  }
}

final class GlassTabBarView: NSObject, FlutterPlatformView, UITabBarDelegate {
  private let bar: UITabBar
  private let channel: FlutterMethodChannel

  init(frame: CGRect, viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
    bar = UITabBar(frame: frame)
    channel = FlutterMethodChannel(name: "\(GlassTabBarFactory.viewType)/\(viewId)", binaryMessenger: messenger)
    super.init()

    bar.overrideUserInterfaceStyle = .dark // l'app è solo scura
    bar.tintColor = .white
    bar.delegate = self

    let entries = args["items"] as? [[String: Any]] ?? []
    bar.items = entries.enumerated().map { index, entry in
      let png = entry["icon"] as? FlutterStandardTypedData
      let face = png.flatMap { UIImage(data: $0.data, scale: 3) }
      let item = UITabBarItem(title: nil, image: face.map { Self.faded($0, alpha: 0.6) }, tag: index)
      item.selectedImage = face.map { Self.faded($0, alpha: 1) }
      item.accessibilityLabel = entry["title"] as? String
      return item
    }
    select(args["selected"] as? Int ?? 0)

    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "select", let index = call.arguments as? Int {
        self?.select(index)
      }
      result(nil)
    }
  }

  func view() -> UIView { bar }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    channel.invokeMethod("select", arguments: item.tag)
  }

  /// Sul vetro iOS forza il colore delle voci non attive: ignora `unselectedItemTintColor`, l'appearance e gli attributi del titolo.
  /// Per questo icona ed etichetta arrivano già disegnate (vedi `_renderFace`) e qui si sceglie solo l'opacità di ogni stato.
  private static func faded(_ image: UIImage, alpha: CGFloat) -> UIImage {
    UIGraphicsImageRenderer(size: image.size).image { _ in
      image.draw(at: .zero, blendMode: .normal, alpha: alpha)
    }.withRenderingMode(.alwaysOriginal)
  }

  private func select(_ index: Int) {
    guard let items = bar.items, items.indices.contains(index), bar.selectedItem !== items[index] else { return }
    bar.selectedItem = items[index]
  }
}
