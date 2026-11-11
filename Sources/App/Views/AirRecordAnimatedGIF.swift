// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION // AIRRECORD_AUTOMATION 조건이 있을 경우 아래 코드를 빌드에 포함함
import ImageIO
import SwiftUI
import UIKit

// 세일러문 GIF, 동작 줄이기 설정 시 GIF 정지
@MainActor
struct AirRecordAnimatedGIF: UIViewRepresentable {
    let url: URL
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> AirRecordGIFImageView {
        AirRecordGIFImageView(frame: .zero)
    }

    func updateUIView(_ view: AirRecordGIFImageView, context: Context) {
        view.configure(url: url, shouldAnimate: isActive && !reduceMotion)
    }

    static func dismantleUIView(_ view: AirRecordGIFImageView, coordinator: ()) {
        view.tearDown()
    }
}

// animationImages에 프레임을 보관하여 GIF 재생, 비활성화 시 정지
@MainActor
final class AirRecordGIFImageView: UIImageView {
    private var resourceURL: URL?
    private var poster: UIImage?
    private var wantsAnimation = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFit
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        NotificationCenter.default.addObserver(self, selector: #selector(suspendAnimation),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeAnimation),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(url: URL, shouldAnimate: Bool) {
        if resourceURL != url {
            stopAndReleaseFrames()
            resourceURL = url
            poster = Self.poster(at: url)
            image = poster
        }
        wantsAnimation = shouldAnimate
        updatePlayback()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePlayback()
    }

    func tearDown() {
        wantsAnimation = false
        stopAndReleaseFrames()
        poster = nil
        image = nil
        resourceURL = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func suspendAnimation() { stopAndReleaseFrames() }
    @objc private func resumeAnimation() { updatePlayback() }

    private func updatePlayback() {
        guard wantsAnimation, window != nil,
              UIApplication.shared.applicationState == .active,
              let resourceURL else {
            stopAndReleaseFrames()
            return
        }
        if animationImages == nil {
            guard let sequence = Self.sequence(at: resourceURL) else { return }
            animationImages = sequence.frames
            animationDuration = sequence.duration
            animationRepeatCount = 0
        }
        if !isAnimating { startAnimating() }
    }

    private func stopAndReleaseFrames() {
        stopAnimating()
        animationImages = nil
        image = poster
    }

    private static func poster(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return UIImage(cgImage: first)
    }

    private static func sequence(at url: URL) -> (frames: [UIImage], duration: TimeInterval)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        var images: [UIImage] = []
        var centiseconds: [Int] = []
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let rawDelay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
            let delay = rawDelay.isFinite && rawDelay > 0 ? rawDelay : 0.1
            // GIF timing is in hundredths of a second. Repeated references give
            // UIImageView evenly spaced frames without losing variable delays.
            centiseconds.append(max(1, Int((delay * 100).rounded())))
            images.append(UIImage(cgImage: frame))
        }
        let divisor = centiseconds.dropFirst().reduce(centiseconds[0], greatestCommonDivisor)
        var weightedFrames: [UIImage] = []
        for (image, delay) in zip(images, centiseconds) {
            weightedFrames.append(contentsOf: repeatElement(image, count: delay / divisor))
        }
        return (weightedFrames, Double(centiseconds.reduce(0, +)) / 100)
    }

    private static func greatestCommonDivisor(_ left: Int, _ right: Int) -> Int {
        var a = left, b = right
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}
#endif
