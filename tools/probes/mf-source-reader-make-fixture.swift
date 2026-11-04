// SPDX-License-Identifier: LGPL-2.1-or-later
// Create the all-keyframe H.264 fixture used by mf-source-reader-seek-probe.
import AVFoundation
import CoreVideo
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("usage: swift mf-source-reader-make-fixture.swift <new-output.mp4>")
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 64,
    AVVideoHeightKey: 64,
    AVVideoCompressionPropertiesKey: [
        AVVideoMaxKeyFrameIntervalKey: 1,
        AVVideoAverageBitRateKey: 200_000,
    ],
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
let attributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: 64,
    kCVPixelBufferHeightKey as String: 64,
]
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input, sourcePixelBufferAttributes: attributes)
guard writer.canAdd(input) else { fatalError("cannot add video input") }
writer.add(input)
guard writer.startWriting() else { fatalError("writer failed: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)

for frame in 0..<120 {
    while !input.isReadyForMoreMediaData {
        guard writer.status == .writing else { fatalError("writer stopped: \(String(describing: writer.error))") }
        Thread.sleep(forTimeInterval: 0.005)
    }
    guard let pool = adaptor.pixelBufferPool else { fatalError("pixel buffer pool unavailable") }
    var value: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &value) == kCVReturnSuccess,
          let pixel = value else { fatalError("pixel buffer allocation failed") }
    CVPixelBufferLockBaseAddress(pixel, [])
    memset(CVPixelBufferGetBaseAddress(pixel)!, Int32(frame % 256), CVPixelBufferGetBytesPerRow(pixel) * 64)
    CVPixelBufferUnlockBaseAddress(pixel, [])
    guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
        fatalError("cannot append frame: \(String(describing: writer.error))")
    }
}
input.markAsFinished()
let completion = DispatchSemaphore(value: 0)
writer.finishWriting { completion.signal() }
completion.wait()
guard writer.status == .completed else { fatalError("writer failed: \(String(describing: writer.error))") }
