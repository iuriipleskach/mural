import Foundation

/// Deterministic token estimation. AFM-class tokenizers average roughly
/// 4 characters per token on English text; we divide UTF-8 byte count by 3
/// so the estimate deliberately over-counts. Over-estimating triggers
/// condensation early; under-estimating would overflow the context window.
public struct TokenEstimator: Sendable, Equatable {
    public let bytesPerToken: Int

    public init(bytesPerToken: Int = 3) {
        self.bytesPerToken = max(1, bytesPerToken)
    }

    public func tokens(in text: String) -> Int {
        let byteCount = text.utf8.count
        guard byteCount > 0 else { return 0 }
        return (byteCount + bytesPerToken - 1) / bytesPerToken
    }

    public func tokens(in texts: [String]) -> Int {
        texts.reduce(0) { $0 + tokens(in: $1) }
    }
}
