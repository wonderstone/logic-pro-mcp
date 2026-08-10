import XCTest
@testable import LogicProMCP

final class OSCTransportTests: XCTestCase {
    func testReadinessGateIgnoresCancellationAfterReady() {
        let gate = OSCConnectionReadinessGate()

        XCTAssertTrue(gate.claim(), "the ready state must settle the start continuation")
        XCTAssertFalse(gate.claim(), "a later cancelled state must not resume it again")
        XCTAssertFalse(gate.claim(), "terminal state handling must remain single-shot")
    }
}
