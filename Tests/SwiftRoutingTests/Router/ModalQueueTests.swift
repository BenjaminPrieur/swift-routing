import Combine
@testable import SwiftRouting
import Testing

/// A modal requested while another one is still dismissing is held by the router and presented once
/// SwiftUI reports the dismissal (`notifyModalDismissed`), because UIKit drops it otherwise.
@MainActor
struct ModalQueueTests {
  private let root = Router(configuration: Configuration())

  /// Presents `route` the way SwiftUI would show it: the slot is set and a presented child router exists.
  private func presentOnScreen(_ route: TestRoute, as kind: ModalKind) -> Router {
    let child = Router(root: AnyRoute(wrapped: route), type: .presented(route.name), parent: root)
    switch kind {
    case .sheet: root.present(route)
    case .cover: root.cover(route)
    }
    return child
  }

  /// What SwiftUI does to the binding when a modal starts dismissing.
  private func startDismissing(_ kind: ModalKind) {
    switch kind {
    case .sheet: root.sheet = nil
    case .cover: root.cover = nil
    }
  }


  private func cover() -> TestRoute? {
    root.cover?.wrapped as? TestRoute
  }

  private func sheet() -> TestRoute? {
    root.sheet?.wrapped as? TestRoute
  }

  struct NothingDismissing {
    @Test
    @MainActor
    func cover_requested_return_presentedImmediately() {
      let root = Router(configuration: Configuration())

      root.cover(TestRoute.home)

      #expect((root.cover?.wrapped as? TestRoute) == .home)
    }

    @Test
    @MainActor
    func sheet_requested_return_presentedImmediately() {
      let root = Router(configuration: Configuration())

      root.present(TestRoute.home)

      #expect((root.sheet?.wrapped as? TestRoute) == .home)
    }

    @Test
    @MainActor
    func coverOnScreen_anotherCoverRequested_return_replacedImmediately() {
      let root = Router(configuration: Configuration())
      let child = Router(root: AnyRoute(wrapped: TestRoute.home), type: .presented("home"), parent: root)
      root.cover(TestRoute.home)

      root.cover(TestRoute.settings)

      #expect((root.cover?.wrapped as? TestRoute) == .settings)
      withExtendedLifetime(child) {}
    }

  }

  @Test(arguments: ModalKind.allCases, ModalKind.allCases)
  func modalDismissing_modalRequested_return_heldUntilDismissalReported(dismissing: ModalKind, requested: ModalKind) {
    let child = presentOnScreen(.home, as: dismissing)
    startDismissing(dismissing)

    switch requested {
    case .sheet: root.present(TestRoute.settings)
    case .cover: root.cover(TestRoute.settings)
    }

    #expect(sheet() == nil)
    #expect(cover() == nil)

    root.notifyModalDismissed(dismissing)

    switch requested {
    case .sheet: #expect(sheet() == .settings)
    case .cover: #expect(cover() == .settings)
    }
    withExtendedLifetime(child) {}
  }

  @Test
  func requestHeld_presentedPublisher_return_trueOnlyOnceShown() {
    var events: [Bool] = []
    let child = presentOnScreen(.home, as: .cover)
    let cancellable = root.present.sink { isPresented, _ in events.append(isPresented) }
    startDismissing(.cover)
    root.cover(TestRoute.settings)
    #expect(events == [false])

    root.notifyModalDismissed(.cover)

    #expect(events == [false, true])
    cancellable.cancel()
    withExtendedLifetime(child) {}
  }

  @Test
  func requestFromPresentFalseObserver_return_heldThenPresented() {
    let child = presentOnScreen(.home, as: .cover)
    let cancellable = root.present.sink { [root] isPresented, _ in
      if !isPresented {
        root.cover(TestRoute.settings)
      }
    }

    startDismissing(.cover)

    #expect(cover() == nil)
    root.notifyModalDismissed(.cover)
    #expect(cover() == .settings)
    cancellable.cancel()
    withExtendedLifetime(child) {}
  }

  @Test
  func secondRequestWhileHeld_return_latestWins() {
    var shown: [TestRoute] = []
    let child = presentOnScreen(.home, as: .cover)
    let cancellable = root.present.sink { [root] isPresented, _ in
      if isPresented, let route = root.cover?.wrapped as? TestRoute {
        shown.append(route)
      }
    }
    startDismissing(.cover)

    root.cover(TestRoute.settings)
    root.cover(TestRoute.details(id: "latest"))
    root.notifyModalDismissed(.cover)

    #expect(cover() == .details(id: "latest"))
    #expect(shown == [.details(id: "latest")])
    cancellable.cancel()
    withExtendedLifetime(child) {}
  }

  @Test
  func requestsOfBothKindsWhileHeld_return_onlyLatestPresented() {
    let child = presentOnScreen(.home, as: .cover)
    startDismissing(.cover)

    root.cover(TestRoute.settings)
    root.present(TestRoute.details(id: "sheet"))
    root.notifyModalDismissed(.cover)

    #expect(cover() == nil)
    #expect(sheet() == .details(id: "sheet"))
    withExtendedLifetime(child) {}
  }

  @Test
  func twoDismissalsInFlight_return_presentedOnlyAfterBothReported() {
    let sheetChild = presentOnScreen(.home, as: .sheet)
    let coverChild = presentOnScreen(.details(id: "1"), as: .cover)
    root.closeChildren()

    root.cover(TestRoute.settings)
    root.notifyModalDismissed(.sheet)
    #expect(cover() == nil)

    root.notifyModalDismissed(.cover)
    #expect(cover() == .settings)
    withExtendedLifetime((sheetChild, coverChild)) {}
  }

  @Test
  func dismissalReportedWithoutKind_return_everythingSettled() {
    let sheetChild = presentOnScreen(.home, as: .sheet)
    let coverChild = presentOnScreen(.details(id: "1"), as: .cover)
    root.closeChildren()
    root.cover(TestRoute.settings)

    root.notifyModalDismissed()

    #expect(cover() == .settings)
    withExtendedLifetime((sheetChild, coverChild)) {}
  }

  @Test
  func afterFlush_nextRequest_return_presentedImmediately() {
    let child = presentOnScreen(.home, as: .cover)
    startDismissing(.cover)
    root.cover(TestRoute.settings)
    root.notifyModalDismissed(.cover)
    startDismissing(.cover)
    root.notifyModalDismissed(.cover)

    root.cover(TestRoute.details(id: "next"))

    #expect(cover() == .details(id: "next"))
    withExtendedLifetime(child) {}
  }

  @Test
  func requestHeld_closeChildren_return_requestDropped() {
    let child = presentOnScreen(.home, as: .cover)
    startDismissing(.cover)
    root.cover(TestRoute.settings)

    root.closeChildren()
    root.notifyModalDismissed(.cover)

    #expect(cover() == nil)
    withExtendedLifetime(child) {}
  }

  @Test
  func requestHeld_routerClosed_return_requestDropped() {
    let modal = Router(root: AnyRoute(wrapped: TestRoute.home), type: .presented("home"), parent: root)
    let grandchild = Router(root: AnyRoute(wrapped: TestRoute.settings), type: .presented("settings"), parent: modal)
    modal.cover(TestRoute.settings)
    modal.cover = nil
    modal.cover(TestRoute.details(id: "held"))
    #expect(modal.cover == nil)

    modal.close()
    modal.notifyModalDismissed(.cover)

    #expect(modal.cover == nil)
    withExtendedLifetime(grandchild) {}
  }


  @Test
  func modalNeverOnScreen_setThenCleared_return_nextRequestPresentedImmediately() {
    root.cover(TestRoute.home)
    root.cover = nil

    root.cover(TestRoute.settings)

    #expect(cover() == .settings)
  }

  @Test
  func dismissedObserverRequestsModal_return_presentedImmediately() {
    let child = presentOnScreen(.home, as: .cover)
    startDismissing(.cover)
    let cancellable = root.dismissed.sink { [root] _ in root.cover(TestRoute.details(id: "from-observer")) }

    root.notifyModalDismissed(.cover)

    #expect(cover() == .details(id: "from-observer"))
    cancellable.cancel()
    withExtendedLifetime(child) {}
  }

  @Test
  func dismissedObserverRequestsModal_return_newerThanHeldRequest() {
    let child = presentOnScreen(.home, as: .cover)
    startDismissing(.cover)
    root.cover(TestRoute.settings)
    let cancellable = root.dismissed.sink { [root] _ in root.cover(TestRoute.details(id: "from-observer")) }

    root.notifyModalDismissed(.cover)

    #expect(cover() == .details(id: "from-observer"))
    cancellable.cancel()
    withExtendedLifetime(child) {}
  }

  @Test
  func coverDeeplink_whileCoverOnScreen_return_presentedOnceDismissalReported() {
    let child = presentOnScreen(.home, as: .cover)

    root.handle(deeplink: DeeplinkRoute.cover(TestRoute.settings))
    #expect(cover() == nil)

    root.notifyModalDismissed(.cover)
    #expect(cover() == .settings)
    withExtendedLifetime(child) {}
  }

  @Test(arguments: [TestDispatchRoute.covered, .sheetWithStack, .sheetWithoutStack])
  func routeCall_whileDismissing_return_heldUntilDismissalReported(route: TestDispatchRoute) {
    let child = presentOnScreen(.home, as: .cover)
    startDismissing(.cover)

    root.route(route)
    #expect(root.cover == nil)
    #expect(root.sheet == nil)

    root.notifyModalDismissed(.cover)
    #expect(root.cover != nil || root.sheet != nil)
    withExtendedLifetime(child) {}
  }
}
