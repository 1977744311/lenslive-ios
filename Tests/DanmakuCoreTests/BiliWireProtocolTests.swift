import XCTest
import DanmakuCore

final class BiliWireProtocolTests: XCTestCase {
    func testEncodeHeartbeatHeaderExactBytes() {
        let data = BiliWireProtocol.encode(op: .heartbeat, sequence: 1)
        XCTAssertEqual([UInt8](data), [
            0x00, 0x00, 0x00, 0x10, // packLen = 16
            0x00, 0x10,             // headerLen = 16
            0x00, 0x00,             // version = 0
            0x00, 0x00, 0x00, 0x02, // operation = 2
            0x00, 0x00, 0x00, 0x01, // sequence = 1
        ])
    }

    func testEncodeDecodeRoundtrip() throws {
        let frames: [(BiliFrameOperation, Data, UInt32)] = [
            (.heartbeat, Data(), 1),
            (.auth, Data(#"{"roomid":1}"#.utf8), 2),
            (.message, Data("弹幕消息 body".utf8), 3),
            (.authReply, Data(#"{"code":0}"#.utf8), 4),
        ]
        var wire = Data()
        for (op, body, seq) in frames {
            wire.append(BiliWireProtocol.encode(op: op, body: body, sequence: seq))
        }

        var decoder = BiliFrameDecoder()
        let decoded = try decoder.decode(wire)

        XCTAssertEqual(decoded.count, frames.count)
        for (index, frame) in decoded.enumerated() {
            XCTAssertEqual(frame.op, frames[index].0)
            XCTAssertEqual(frame.body, frames[index].1)
            XCTAssertEqual(frame.sequence, frames[index].2)
            XCTAssertEqual(frame.version, 0)
        }
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testStickyAndPartialPackets() throws {
        let frameA = BiliWireProtocol.encode(op: .message, body: Data("hello".utf8), sequence: 1)
        let frameB = BiliWireProtocol.encode(op: .message, body: Data("world!".utf8), sequence: 2)
        var combined = Data()
        combined.append(frameA)
        combined.append(frameB) // A 长 21，B 长 22，共 43

        var decoder = BiliFrameDecoder()

        // 切片 1：A 的半个头 → 无帧，字节留缓冲
        let chunk1 = combined.subdata(in: 0..<10)
        XCTAssertEqual(try decoder.decode(chunk1), [])
        XCTAssertEqual(decoder.bufferedByteCount, 10)

        // 切片 2：补齐 A + B 的部分头（粘包 + 半包）→ 只出 A
        let chunk2 = combined.subdata(in: 10..<25)
        let second = try decoder.decode(chunk2)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].body, Data("hello".utf8))
        XCTAssertEqual(decoder.bufferedByteCount, 4)

        // 切片 3：补齐 B → 出 B，缓冲清空
        let chunk3 = combined.subdata(in: 25..<combined.count)
        let third = try decoder.decode(chunk3)
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(third[0].body, Data("world!".utf8))
        XCTAssertEqual(third[0].sequence, 2)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testEmptyBodyFrameBetweenFrames() throws {
        var wire = BiliWireProtocol.encode(op: .message, body: Data("a".utf8), sequence: 1)
        wire.append(BiliWireProtocol.encode(op: .heartbeatReply, sequence: 2))
        wire.append(BiliWireProtocol.encode(op: .message, body: Data("b".utf8), sequence: 3))

        var decoder = BiliFrameDecoder()
        let frames = try decoder.decode(wire)

        XCTAssertEqual(frames.map(\.op), [.message, .heartbeatReply, .message])
        XCTAssertEqual(frames[1].body, Data())
    }

    func testMalformedHeaderThrowsAndClearsBuffer() {
        var bad = BiliWireProtocol.encode(op: .heartbeat, sequence: 1)
        bad[5] = 0x0F // headerLen 改成 15

        var decoder = BiliFrameDecoder()
        XCTAssertThrowsError(try decoder.decode(bad)) { error in
            XCTAssertEqual(error as? BiliWireProtocolError, .malformedHeader)
        }
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testOversizeFrameThrows() {
        var bad = Data()
        let declared = UInt32(BiliWireProtocol.maxFrameLength + 1)
        withUnsafeBytes(of: declared.bigEndian) { bad.append(contentsOf: $0) }
        bad.append(contentsOf: [0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x01])

        var decoder = BiliFrameDecoder()
        XCTAssertThrowsError(try decoder.decode(bad)) { error in
            XCTAssertEqual(error as? BiliWireProtocolError,
                           .frameTooLarge(declared: BiliWireProtocol.maxFrameLength + 1))
        }
    }

    func testUnknownOperationPreserved() throws {
        var wire = Data()
        wire.append(contentsOf: [0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00, 0x00])
        wire.append(contentsOf: [0x00, 0x00, 0x00, 0x63]) // operation = 99
        wire.append(contentsOf: [0x00, 0x00, 0x00, 0x01])

        var decoder = BiliFrameDecoder()
        let frames = try decoder.decode(wire)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].operation, 99)
        XCTAssertNil(frames[0].op)
    }
}
