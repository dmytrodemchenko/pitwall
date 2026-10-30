import os
import XCTest
@testable import Pitwall

@MainActor
final class GitStatusTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(Git.parse(branch: "main\n", porcelain: " M a.swift\n?? b.txt\nR  c -> d\n"), GitInfo(branch: "main", changed: 3))
        XCTAssertEqual(Git.parse(branch: "main\n", porcelain: ""), GitInfo(branch: "main", changed: 0))
        XCTAssertEqual(GitInfo(branch: "main", changed: 4).summary, "main · 4 changed")
        XCTAssertEqual(GitInfo(branch: "main", changed: 0).summary, "main · no changes")
    }

    func testRealRepository() throws {
        let dir = tempDir()
        func git(_ args: String...) { XCTAssertNotNil(Git.run(["-C", dir.path] + args, timeout: 10), args.joined(separator: " ")) }
        git("init", "-q", "-b", "trunk")
        try "a".write(to: dir.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        git("add", "a.txt")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "first")
        XCTAssertEqual(Git.status(of: dir.path), GitInfo(branch: "trunk", changed: 0))
        try "b".write(to: dir.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: dir.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Git.status(of: dir.path), GitInfo(branch: "trunk", changed: 2)) // modified + untracked
    }

    func testNotARepositoryHidesTheRow() {
        XCTAssertNil(Git.status(of: tempDir().path))
        XCTAssertNil(Git.status(of: "/no/such/folder"))
    }

    func testTimeoutKillsTheCommand() {
        let start = Date()
        XCTAssertNil(Git.run(["5"], executable: "/bin/sleep", timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testRefreshesAtMostOncePerIntervalAndKeepsTheLast() {
        let store = GitStatusStore()
        store.interval = 0.5
        let calls = OSAllocatedUnfairLock(initialState: 0)
        store.lookup = { _ in GitInfo(branch: "main", changed: calls.withLock { $0 += 1; return $0 }) }
        func pause(_ seconds: TimeInterval) {
            let idle = expectation(description: "pause")
            idle.isInverted = true
            wait(for: [idle], timeout: seconds)
        }
        for _ in 0..<5 { store.refresh("/p") } // a burst of edits
        pause(0.2)
        XCTAssertEqual(calls.withLock { $0 }, 1) // the first one runs at once
        XCTAssertEqual(store.info["/p"]?.changed, 1)
        pause(0.6)
        XCTAssertEqual(calls.withLock { $0 }, 2) // one trailing run picks up the rest
        XCTAssertEqual(store.info["/p"]?.changed, 2)
        pause(0.8)
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertTrue(store.hasChecked("/p"))
        XCTAssertFalse(store.hasChecked("/other"))
    }
}
