import Foundation
import Testing
@testable import ReaderCore

@Suite struct NavigationHistoryTests {
    private func entry(_ page: Int) -> NavEntry {
        NavEntry(pageIndex: page, point: CGPoint(x: 10, y: 20), scaleFactor: 1.5)
    }

    @Test func startsEmpty() {
        let history = NavigationHistory()
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test func goBackOnEmptyReturnsNil() {
        var history = NavigationHistory()
        #expect(history.goBack(from: entry(0)) == nil)
        #expect(history.goForward(from: entry(0)) == nil)
    }

    @Test func pushThenBackReturnsPushedEntry() {
        var history = NavigationHistory()
        history.push(entry(3))
        let target = history.goBack(from: entry(7))
        #expect(target == entry(3))
        #expect(history.canGoForward)
        #expect(!history.canGoBack)
    }

    @Test func backThenForwardRoundTrips() {
        var history = NavigationHistory()
        history.push(entry(1))
        let current = entry(9)
        let back = history.goBack(from: current)
        #expect(back == entry(1))
        let forwardAgain = history.goForward(from: back!)
        #expect(forwardAgain == current)
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test func pushClearsForwardStack() {
        var history = NavigationHistory()
        history.push(entry(1))
        _ = history.goBack(from: entry(2))
        #expect(history.canGoForward)
        history.push(entry(5))
        #expect(!history.canGoForward)
    }

    @Test func backStackIsCapped() {
        var history = NavigationHistory()
        for i in 0..<(NavigationHistory.maxEntries + 50) {
            history.push(entry(i))
        }
        #expect(history.back.count == NavigationHistory.maxEntries)
        // Oldest entries were discarded; newest survive.
        #expect(history.back.last == entry(NavigationHistory.maxEntries + 49))
        #expect(history.back.first == entry(50))
    }

    @Test func multiStepBackAndForward() {
        var history = NavigationHistory()
        // Visit pages 0 -> 1 -> 2 -> 3, pushing the position left behind.
        for i in 0..<3 {
            history.push(entry(i))
        }
        var current = entry(3)
        // Walk all the way back to 0.
        for expected in stride(from: 2, through: 0, by: -1) {
            current = history.goBack(from: current)!
            #expect(current.pageIndex == expected)
        }
        #expect(!history.canGoBack)
        // Walk forward to 3 again.
        for expected in 1...3 {
            current = history.goForward(from: current)!
            #expect(current.pageIndex == expected)
        }
        #expect(!history.canGoForward)
    }
}
