@testable import RsyncProcessStreaming
import XCTest

final class RsyncProcessStreamingTests: XCTestCase {
    func testAccumulatorSplitsLines() async {
        let accumulator = StreamAccumulator()
        let first = await accumulator.consume("one\ntwo\npart")
        XCTAssertEqual(first, ["one", "two"])
        let second = await accumulator.consume("ial\nthree\n")
        XCTAssertEqual(second, ["partial", "three"])
        _ = await accumulator.flushTrailing()
        let snapshot = await accumulator.snapshot()
        XCTAssertEqual(snapshot, ["one", "two", "partial", "three"])
    }
}
