#if canImport(UIKit)
import Combine
import SwiftUI
import UIKit

@testable import SwiftRouting

/// Hosts a `RoutingView` in a real `UIWindow` so sheets and full-screen covers are really presented.
@MainActor
final class HostedRouterHarness {

  final class RouterBox {
    weak var router: Router?
  }

  private struct Probe: View {
    @Environment(\.router) private var router
    let box: RouterBox

    var body: some View {
      Color.clear.onAppear { box.router = router }
    }
  }

  /// UIKit only completes a modal transition when the tests run inside an app with a live scene;
  /// the hostless `swift test` bundle never finishes presenting or dismissing anything.
  static var activeScene: UIWindowScene? {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
  }

  nonisolated static var isAppHosted: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

  let window: UIWindow
  let controller: UIViewController
  private let box = RouterBox()
  var cancellables = Set<AnyCancellable>()

  var root: Router? { box.router }

  init() {
    let box = box
    controller = UIHostingController(
      rootView: RoutingView(destination: HostedDestination.self, root: HostedRoute.home) { Probe(box: box) }
    )
    if let scene = HostedRouterHarness.activeScene {
      window = UIWindow(windowScene: scene)
    } else {
      window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    }
    window.rootViewController = controller
    window.makeKeyAndVisible()
  }

  /// The topmost view controller UIKit is actually showing.
  var topPresented: UIViewController? {
    var top = controller.presentedViewController
    while let next = top?.presentedViewController { top = next }
    return top
  }

  var isPresentingAnything: Bool { controller.presentedViewController != nil }

  /// A live presented child router of `root` whose root route is `route`.
  func presentedChild(for route: HostedRoute) -> Router? {
    root?.children.values
      .compactMap { $0.value as? Router }
      .first { $0.isPresented && ($0.root.wrapped as? HostedRoute) == route }
  }

  func waitFor(timeout: TimeInterval = 4, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
  }

  func settle(_ seconds: TimeInterval = 1.5) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }

  func tearDown() {
    window.isHidden = true
    window.rootViewController = nil
  }
}

enum HostedRoute: Route {
  case home
  case first
  case second
  case third

  var name: String {
    switch self {
    case .home: "home"
    case .first: "first"
    case .second: "second"
    case .third: "third"
    }
  }
}

enum HostedDestination: RouteDestination {
  static func view(for route: HostedRoute) -> some View {
    Text(route.name)
  }
}
#endif
