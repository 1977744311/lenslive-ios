// B 站开放平台长连二进制帧编解码（纯函数 + 值类型缓冲解码器，可离线单测）。
// 帧结构：16 字节大端头 [packLen:u32][headerLen:u16=16][version:u16][operation:u32][sequence:u32] + body。
// 开放平台通道 version=0 明文，无 zlib/brotli 压缩。
import Foundation

public enum BiliFrameOperation: UInt32, Sendable {
    case heartbeat = 2       // 客户端心跳，空 body
    case heartbeatReply = 3  // 服务端心跳回应
    case message = 5         // 业务消息，body 为 JSON
    case auth = 7            // 鉴权，body 为 start 响应中的 auth_body 原文
    case authReply = 8       // 鉴权回应
}

public struct BiliFrame: Sendable, Equatable {
    public var version: UInt16
    /// 保留原始操作码：未知 op 不丢帧，由上层决定忽略。
    public var operation: UInt32
    public var sequence: UInt32
    public var body: Data

    public init(version: UInt16, operation: UInt32, sequence: UInt32, body: Data) {
        self.version = version
        self.operation = operation
        self.sequence = sequence
        self.body = body
    }

    public var op: BiliFrameOperation? { BiliFrameOperation(rawValue: operation) }
}

public enum BiliWireProtocolError: Error, Equatable, Sendable {
    case malformedHeader
    case frameTooLarge(declared: Int)
}

public enum BiliWireProtocol {
    public static let headerLength = 16
    /// 单帧上限，防御异常 packLen 导致的无界缓冲。
    public static let maxFrameLength = 1 << 24

    public static func encode(op: BiliFrameOperation,
                              body: Data = Data(),
                              sequence: UInt32 = 0,
                              version: UInt16 = 0) -> Data {
        var data = Data(capacity: headerLength + body.count)
        appendBigEndian(UInt32(headerLength + body.count), to: &data)
        appendBigEndian(UInt16(headerLength), to: &data)
        appendBigEndian(version, to: &data)
        appendBigEndian(op.rawValue, to: &data)
        appendBigEndian(sequence, to: &data)
        data.append(body)
        return data
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

/// 流式解码器：吸收任意字节切片（粘包/半包），完整帧出队，不足一帧的字节留在缓冲。
/// 头部非法时清空缓冲并抛错（字节流已失步，调用方应重连）。
public struct BiliFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public mutating func decode(_ data: Data) throws -> [BiliFrame] {
        buffer.append(data)
        var frames: [BiliFrame] = []
        let bytes = [UInt8](buffer)
        var offset = 0
        while bytes.count - offset >= BiliWireProtocol.headerLength {
            let packLen = Int(readUInt32(bytes, at: offset))
            let headerLen = Int(readUInt16(bytes, at: offset + 4))
            guard headerLen == BiliWireProtocol.headerLength, packLen >= headerLen else {
                buffer.removeAll()
                throw BiliWireProtocolError.malformedHeader
            }
            guard packLen <= BiliWireProtocol.maxFrameLength else {
                buffer.removeAll()
                throw BiliWireProtocolError.frameTooLarge(declared: packLen)
            }
            guard bytes.count - offset >= packLen else { break }
            frames.append(BiliFrame(
                version: readUInt16(bytes, at: offset + 6),
                operation: readUInt32(bytes, at: offset + 8),
                sequence: readUInt32(bytes, at: offset + 12),
                body: Data(bytes[(offset + headerLen)..<(offset + packLen)])
            ))
            offset += packLen
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return frames
    }

    private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}
