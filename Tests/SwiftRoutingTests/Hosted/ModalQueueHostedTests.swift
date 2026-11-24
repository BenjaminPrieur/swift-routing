#if canImport(UIKit)
import Combine
@testable import SwiftRouting
import Testing
import UIKit

/// Hosts the router in a real `UIWindow`: SwiftUI's `sheet`/`fullScreenCover` only exist there.
@MainActor
@Suite(.enabled(if: HostedRouterHarness.isAppHosted, "needs an app host: modal transitions never finish in a hostless bundle"))
struct ModalQueueHostedTests {

  enum Kind: String, CaseIterable, CustomTestStringConvertible {
    case sheet
    case cover

    var testDescription: String {
      rawValue
    }

    @MainActor
    func present(_ route: HostedRoute, on router: Router) {
      switch self {
      case .sheet: router.present(route, withStack: false)
      case .cover: router.cover(route)
      }
    }
  }

  enum Dismissal: String, CaseIterable, CustomTestStringConvertible {
    /// `close()` on the presented router, which goes through `CloseModifier`'s native `dismiss()`.
    case close
    case closeChildren

    var testDescription: String {
      rawValue
    }
  }

  enum RequestTiming: String, CaseIterable, CustomTestStringConvertible {
    /// From the `routerPresent(false)` callback, in the same turn the slot clears.
    case synchronous
    /// A few frames later, while the dismiss animation is still running.
    case duringAnimation
    /// Control: well after the dismissal is over, so nothing is in flight.
    case afterSettled

    var testDescription: String {
      rawValue
    }
  }

  /// Presents `first`, dismisses it, requests `second` while that dismissal is in flight, and reports
  /// whether `second` ends up on screen.
  private func requestWhileDismissing(
    first: Kind,
    second: Kind,
    dismissal: Dismissal,
    timing: RequestTiming
  ) async throws -> Outcome {
    let host = HostedRouterHarness()
    defer { host.tearDown() }
    await host.settle(0.5)
    let root = try #require(host.root)

    first.present(.first, on: root)
    #expect(await host.waitFor { host.presentedChild(for: .first) != nil })
    await host.settle(0.8)
    let child = try #require(host.presentedChild(for: .first))

    var requested = false
    let cancellable = root.present.sink { isPresented, router in
      guard !isPresented, router === root, !requested else { return }
      requested = true
      switch timing {
      case .synchronous:
        second.present(.second, on: root)
      case .duringAnimation:
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 120000000)
          second.present(.second, on: root)
        }
      case .afterSettled:
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 2_000_000_000)
          second.present(.second, on: root)
        }
      }
    }
    defer { cancellable.cancel() }

    switch dismissal {
    case .close: child.close()
    case .closeChildren: root.closeChildren()
    }

    let shown = await host.waitFor(timeout: 5) { host.presentedChild(for: .second) != nil }
    await host.settle(0.5)
    let isShown = shown && host.isPresentingAnything
    let routerHoldsRequest = root.sheet?.wrapped as? HostedRoute == .second
      || root.cover?.wrapped as? HostedRoute == .second
    return Outcome(requested: requested, isShown: isShown, isGhost: routerHoldsRequest && !isShown)
  }

  struct Outcome {
    let requested: Bool
    let isShown: Bool
    /// The router holds the request, but nothing is on screen: SwiftUI dropped it.
    let isGhost: Bool
  }

  @Test
  func probe_cover_presentsInHostedWindow() async throws {
    let host = HostedRouterHarness()
    defer { host.tearDown() }
    await host.settle(0.5)
    let root = try #require(host.root)

    root.cover(HostedRoute.first)

    #expect(await host.waitFor { host.isPresentingAnything })
    #expect(host.presentedChild(for: .first) != nil)
  }

  @Test(arguments: Dismissal.allCases, RequestTiming.allCases)
  func coverRequestedWhileCoverDismisses_isPresented(dismissal: Dismissal, timing: RequestTiming) async throws {
    let outcome = try await requestWhileDismissing(first: .cover, second: .cover, dismissal: dismissal, timing: timing)

    #expect(outcome.requested)
    #expect(outcome.isShown, "ghost cover: router holds it but nothing is on screen = \(outcome.isGhost)")
  }

  @Test(arguments: Dismissal.allCases, RequestTiming.allCases)
  func coverRequestedWhileSheetDismisses_isPresented(dismissal: Dismissal, timing: RequestTiming) async throws {
    let outcome = try await requestWhileDismissing(first: .sheet, second: .cover, dismissal: dismissal, timing: timing)

    #expect(outcome.requested)
    #expect(outcome.isShown, "ghost cover: router holds it but nothing is on screen = \(outcome.isGhost)")
  }

  @Test(arguments: Dismissal.allCases, RequestTiming.allCases)
  func sheetRequestedWhileSheetDismisses_isPresented(dismissal: Dismissal, timing: RequestTiming) async throws {
    let outcome = try await requestWhileDismissing(first: .sheet, second: .sheet, dismissal: dismissal, timing: timing)

    #expect(outcome.requested)
    #expect(outcome.isShown, "ghost sheet: router holds it but nothing is on screen = \(outcome.isGhost)")
  }

  @Test(arguments: Dismissal.allCases, RequestTiming.allCases)
  func sheetRequestedWhileCoverDismisses_isPresented(dismissal: Dismissal, timing: RequestTiming) async throws {
    let outcome = try await requestWhileDismissing(first: .cover, second: .sheet, dismissal: dismissal, timing: timing)

    #expect(outcome.requested)
    #expect(outcome.isShown, "ghost sheet: router holds it but nothing is on screen = \(outcome.isGhost)")
  }

  @Test
  func modalSetAndClearedInSameTurn_nextRequest_isPresented() async throws {
    let host = HostedRouterHarness()
    defer { host.tearDown() }
    await host.settle(0.5)
    let root = try #require(host.root)

    root.cover(HostedRoute.first)
    root.closeChildren()
    root.cover(HostedRoute.second)

    #expect(await host.waitFor { host.presentedChild(for: .second) != nil })
  }


  @Test
  func requestHeldWhileDismissing_closeChildren_isNeverPresented() async throws {
    let host = HostedRouterHarness()
    defer { host.tearDown() }
    await host.settle(0.5)
    let root = try #require(host.root)
    root.cover(HostedRoute.first)
    #expect(await host.waitFor { host.presentedChild(for: .first) != nil })
    await host.settle(0.8)

    host.presentedChild(for: .first)?.close()
    root.cover(HostedRoute.second)
    root.closeChildren()
    await host.settle(2)

    #expect(host.presentedChild(for: .second) == nil)
    #expect(!host.isPresentingAnything)
  }
}
#endif
