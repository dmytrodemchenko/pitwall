import SwiftUI
import XCTest
@testable import Pitwall

@MainActor
final class CardLayoutTests: XCTestCase {
    /// Every mock card, with all its rows, stays under 220 pt at the popover's width.
    @MainActor
    func testCardHeightStaysUnder220() {
        let (store, usage) = Mock.stores()
        for s in store.activeSessions {
            let view = NSHostingView(rootView: SessionCard(session: s, entries: usage.entries(for: s.id),
                                                           prices: Mock.prices, live: false, context: usage.contexts[s.id],
                                                           contextWindows: Mock.contextWindows,
                                git: s.folder.flatMap { Mock.git[$0] }).frame(width: 336))
            XCTAssertLessThan(view.fittingSize.height, 220, s.project)
        }
    }
}
