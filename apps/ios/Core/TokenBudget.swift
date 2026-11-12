import Foundation

/// The hard token budget for model calls.
/// `callBudget` is the maximum prompt size; `responseReserve` is held back
/// for the model's reply so prompt + response always fit `contextWindow`.
public struct TokenBudget: Sendable, Equatable {
    public let contextWindow: Int
    public let callBudget: Int
    public let responseReserve: Int

    /// AFM defaults per Apple TN3193: 4,096-token window, ~3,200 prompt
    /// budget, the rest reserved for the structured response.
    public static let afmDefault = TokenBudget(
        validContextWindow: 4096,
        callBudget: 3200,
        responseReserve: 640
    )

    public init?(contextWindow: Int, callBudget: Int, responseReserve: Int) {
        guard contextWindow > 0,
              callBudget > 0,
              responseReserve >= 0,
              callBudget + responseReserve <= contextWindow
        else {
            return nil
        }
        self.init(
            validContextWindow: contextWindow,
            callBudget: callBudget,
            responseReserve: responseReserve
        )
    }

    private init(validContextWindow: Int, callBudget: Int, responseReserve: Int) {
        self.contextWindow = validContextWindow
        self.callBudget = callBudget
        self.responseReserve = responseReserve
    }

    public func fits(promptTokens: Int) -> Bool {
        promptTokens <= callBudget
    }
}
