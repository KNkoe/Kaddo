import XCTest
@testable import Kaddo

final class DesktopTypingTests: XCTestCase {
    func testTypingChunksPreserveEmojiAcrossEveryPossibleBoundary() {
        for prefix in 0..<40 {
            let text = String(repeating: "a", count: prefix) + "😀👩🏽‍💻\n尾" + String(repeating: "z", count: 41)
            let chunks = DesktopAction.typingChunks(text)
            XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 20 })
            XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
            XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF16.self) }.joined(), text)
        }
        XCTAssertTrue(DesktopAction.typingChunks("").isEmpty)
        XCTAssertEqual(DesktopAction.typingChunks("😀", maximumUnits: 1).map { String(decoding: $0, as: UTF16.self) }.joined(), "😀")
    }
}
