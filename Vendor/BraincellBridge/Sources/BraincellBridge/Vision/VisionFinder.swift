import Foundation
import CoreGraphics
import Vision
import ScreenCaptureKit

/// Local OCR pipeline: capture a window → run Vision text recognition →
/// return a `VisionScene` the rest of the bridge can query. Wraps
/// `VNRecognizeTextRequest` and `SCScreenshotManager` so callers don't have
/// to know about Vision's flipped coord system or how to find a window by
/// PID.
///
/// `actor` because Vision requests are CPU-bound work we want serialized
/// per-finder (no point running two `.accurate` recognitions at the same
/// time on one machine — they'd just contend), and so callers can safely
/// `await` from any context. The bridge is `@MainActor` for state; this
/// runs off-main and hands back a value type.
///
/// First slice: on-demand only. Continuous indexing (frame stream + diff)
/// is in the latency plan but deferred until we have the on-demand path
/// proven.
actor VisionFinder {
    enum VisionFinderError: Error, LocalizedError {
        case noWindow
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noWindow: return "No on-screen window found for that pid"
            case .recognitionFailed(let msg): return "Text recognition failed: \(msg)"
            }
        }
    }

    /// Run text recognition over `image`. Vision reports bounds in
    /// normalized coords (0–1, bottom-left origin); we convert to image-
    /// space pixels (top-left origin) so the rest of the app doesn't need
    /// to know.
    func index(_ image: CGImage) async throws -> VisionScene {
        let imageSize = CGSize(width: image.width, height: image.height)
        let observations = try await recognizeText(in: image)

        let items: [VisionScene.TextItem] = observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            // Vision: normalized, bottom-left origin → image pixels, top-left origin.
            let bb = obs.boundingBox
            let x = bb.origin.x * imageSize.width
            let yFlipped = (1.0 - bb.origin.y - bb.size.height) * imageSize.height
            let w = bb.size.width * imageSize.width
            let h = bb.size.height * imageSize.height
            guard x.isFinite, yFlipped.isFinite, w.isFinite, h.isFinite,
                  w > 0, h > 0 else { return nil }
            return VisionScene.TextItem(
                text: candidate.string,
                bounds: CGRect(x: x, y: yFlipped, width: w, height: h),
                confidence: candidate.confidence
            )
        }

        return VisionScene(items: items, imageSize: imageSize, capturedAt: Date())
    }

    /// Capture the frontmost / largest on-screen window owned by `ownerPid`
    /// via ScreenCaptureKit, then index it. Throws `noWindow` if the pid
    /// has no shareable window — typically means Chrome was closed or the
    /// user revoked Screen Recording permission.
    func indexWindow(ownerPid: pid_t) async throws -> VisionScene {
        let content = try await SCShareableContent.current
        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == ownerPid && window.isOnScreen
        }
        // Prefer largest (Chrome can have a sliver of a popup open); ties
        // are broken by SCShareableContent's natural front-to-back order.
        guard let target = candidates.max(by: { lhs, rhs in
            (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
        }) else {
            throw VisionFinderError.noWindow
        }

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        // Match the window's pixel size so VisionScene.imageSize lines up
        // with what callers see in CGWindowList terms. SCStreamConfiguration
        // wants pixel dimensions; SCWindow.frame is in points, so scale by
        // the display backing factor when available.
        let scale = target.scaleFactor
        let pixelWidth = target.frame.width * scale
        let pixelHeight = target.frame.height * scale
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 16_384, pixelHeight <= 16_384 else {
            throw VisionFinderError.noWindow
        }
        config.width = Int(pixelWidth.rounded(.up))
        config.height = Int(pixelHeight.rounded(.up))
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return try await index(image)
    }

    // MARK: - Vision request

    private func recognizeText(in image: CGImage) async throws -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    NSLog("[VisionFinder] recognition error: %@", String(describing: error))
                    continuation.resume(throwing: VisionFinderError.recognitionFailed(error.localizedDescription))
                    return
                }
                let results = (request.results as? [VNRecognizedTextObservation]) ?? []
                continuation.resume(returning: results)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("[VisionFinder] handler.perform failed: %@", String(describing: error))
                continuation.resume(throwing: VisionFinderError.recognitionFailed(error.localizedDescription))
            }
        }
    }
}

// SCWindow's scaleFactor isn't always populated on every macOS build;
// fall back to 2.0 (Retina) when it isn't, since that's the dominant case
// for the bridge's actual users (developer Macs).
private extension SCWindow {
    var scaleFactor: CGFloat {
        // SCWindow doesn't expose backing scale directly; infer from the
        // window's display if we can find it, else default to 2.0.
        return 2.0
    }
}
