//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

private let maxOneByteSize = 125
private let maxTwoByteSize = Int(UInt16.max)
#if arch(arm) || arch(i386)
// on 32-bit platforms we can't put a whole UInt32 in an Int
private let maxNIOFrameSize = Int(UInt32.max / 2)
#else
// on 64-bit platforms this works just fine
private let maxNIOFrameSize = Int(UInt32.max)
#endif

/// An inbound `ChannelHandler` that serializes structured websocket frames into a byte stream
/// for sending on the network.
///
/// This encoder has limited enforcement of compliance to RFC 6455. In particular, to guarantee
/// that the encoder can handle arbitrary extensions, only normative MUST/MUST NOTs that do not
/// relate to extensions (e.g. the requirement that control frames not have lengths larger than
/// 125 bytes) are enforced by this encoder.
///
/// This encoder does not have any support for encoder extensions. If you wish to support
/// extensions, you should implement a message-to-message encoder that performs the appropriate
/// frame transformation as needed.
public final class WebSocketFrameEncoder: ChannelOutboundHandler {
    public typealias OutboundIn = WebSocketFrame
    public typealias OutboundOut = ByteBuffer

    /// This buffer is used to write frame headers into. We hold a buffer here as it's possible we'll be
    /// able to avoid some allocations by re-using it.
    private var headerBuffer: ByteBuffer? = nil

    /// The maximum size of a websocket frame header. One byte for the frame "first byte", one more for the first
    /// length byte and the mask bit, potentially up to 8 more bytes for a 64-bit length field, and potentially 4 bytes
    /// for a mask key.
    private static let maximumFrameHeaderLength: Int = (2 + 4 + 8)

    public init() { }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.headerBuffer = context.channel.allocator.buffer(capacity: WebSocketFrameEncoder.maximumFrameHeaderLength)
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.headerBuffer = nil
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)

        // Grab the header buffer. We nil it out while we're in this call to avoid the risk of CoWing when we
        // write to it.
        guard var buffer = self.headerBuffer else {
            fatalError("Channel handler lifecycle violated: did not allocate header buffer")
        }
        self.headerBuffer = nil
        buffer.clear()

        // Calculate some information about the mask.
        let maskBitMask: UInt8 = data.maskKey != nil ? 0x80 : 0x00

        // Time to add the extra bytes. To avoid checking this twice, we also start writing stuff out here.
        switch data.length {
        case 0...maxOneByteSize:
            buffer.writeInteger(data.firstByte)
            buffer.writeInteger(UInt8(data.length) | maskBitMask)
        case (maxOneByteSize + 1)...maxTwoByteSize:
            buffer.writeInteger(data.firstByte)
            buffer.writeInteger(UInt8(126) | maskBitMask)
            buffer.writeInteger(UInt16(data.length))
        case (maxTwoByteSize + 1)...maxNIOFrameSize:
            buffer.writeInteger(data.firstByte)
            buffer.writeInteger(UInt8(127) | maskBitMask)
            buffer.writeInteger(UInt64(data.length))
        default:
            fatalError("NIO cannot serialize frames longer than \(maxNIOFrameSize)")
        }

        if let maskKey = data.maskKey {
            buffer.writeBytes(maskKey)
        }

        // Ok, frame header away! Before we send it we save it back onto ourselves in case we get recursively called.
        self.headerBuffer = buffer
        context.write(self.wrapOutboundOut(buffer), promise: nil)

        // Next, let's mask the extension and application data and send
        // them too.
        let (extensionData, applicationData) = self.mask(key: data.maskKey, extensionData: data.extensionData, applicationData: data.data)

        // Now we can send our byte buffers out. We attach the write promise to the last
        // of the frame data.
        if let extensionData = extensionData {
            context.write(self.wrapOutboundOut(extensionData), promise: nil)
        }
        context.write(self.wrapOutboundOut(applicationData), promise: promise)
    }

    /// Applies the websocket masking operation based on the passed byte buffers.
    private func mask(key: WebSocketMaskingKey?, extensionData: ByteBuffer?, applicationData: ByteBuffer) -> (ByteBuffer?, ByteBuffer) {
        guard let key = key else {
            return (extensionData, applicationData)
        }

        // We take local "copies" here. This is only an issue if someone else is holding onto the parent buffers.
        var extensionData = extensionData
        var applicationData = applicationData

        extensionData?.webSocketMask(key)
        applicationData.webSocketMask(key, indexOffset: (extensionData?.readableBytes ?? 0) % 4)
        return (extensionData, applicationData)
    }
}
