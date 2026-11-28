import Flutter
import UIKit

/// Reports where the system puts bars along the edges of the app's view
/// (iOS 27.1+ bar layout regions) to `SystemBars` in Dart.
public final class FlLibPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private weak var registrar: FlutterPluginRegistrar?
  private var probe: BarProbe?

  init(channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar) {
    self.channel = channel
    self.registrar = registrar
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "fl_lib/system_bars", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(
      FlLibPlugin(channel: channel, registrar: registrar), channel: channel)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    probe?.onChange = nil
    probe?.removeFromSuperview()
    probe = nil
    channel.setMethodCallHandler(nil)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "watch" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard #available(iOS 27.1, *) else {
      result([String: [Double]]())
      return
    }
    guard let view = registrar?.viewController?.view else {
      result(FlutterError(code: "no_view", message: "No Flutter view yet", details: nil))
      return
    }
    let probe: BarProbe
    if let current = self.probe, current.superview === view {
      probe = current
    } else {
      self.probe?.onChange = nil
      self.probe?.removeFromSuperview()
      probe = BarProbe(frame: view.bounds)
      probe.onChange = { [weak channel] in channel?.invokeMethod("changed", arguments: $0) }
      view.addSubview(probe)
      self.probe = probe
    }
    let extents = (call.arguments as? [String: Double]) ?? [:]
    result(probe.update(extents: extents))
  }
}

/// An invisible view that fills the Flutter view and re-reads the bar areas
/// whenever its size or safe area changes (rotation, folding, status bar).
private final class BarProbe: UIView {
  var onChange: (([String: [Double]]) -> Void)?
  /// Bar thickness per edge name, from Dart.
  private var extents: [String: Double] = [:]
  private var last: [String: [Double]] = [:]

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isHidden = true
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func update(extents: [String: Double]) -> [String: [Double]] {
    self.extents = extents
    let now = bars()
    last = now
    return now
  }

  /// Each watched edge's bar area as [left, top, width, height] in points.
  func bars() -> [String: [Double]] {
    guard #available(iOS 27.1, *), !bounds.isEmpty else { return [:] }
    let edges: [String: UIRectEdge] = ["left": .left, "top": .top, "right": .right, "bottom": .bottom]
    var out: [String: [Double]] = [:]
    for (name, extent) in extents {
      guard let edge = edges[name], extent.isFinite, extent > 0 else { continue }
      let r = bounds.inset(by: edgeInsets(for: .bar(onEdge: edge, extent: CGFloat(extent))))
      guard !r.isNull, !r.isInfinite, r.size.width > 0, r.size.height > 0 else { continue }
      let rect = [r.origin.x, r.origin.y, r.size.width, r.size.height].map(Double.init)
      guard rect.allSatisfy(\.isFinite) else { continue }
      out[name] = rect
    }
    return out
  }

  private func report() {
    let now = bars()
    guard now != last else { return }
    last = now
    onChange?(now)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    report()
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    report()
  }
}
