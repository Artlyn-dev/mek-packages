import Foundation
import StripeTerminal

@available(iOS 14.0, *)
class TerminalDelegatePlugin: NSObject, ConnectionTokenProvider, TerminalDelegate {
    private let handlers: TerminalHandlersApi

    init(_ handlers: TerminalHandlersApi) {
        self.handlers = handlers
    }
    
    public func fetchConnectionToken() async throws -> String {
        return try await self.handlers.requestConnectionToken()
    }

    @available(iOS 14.0, *)
    public func terminal(_: Terminal, didChangePaymentStatus status: PaymentStatus) {
        DispatchQueue.main.async {
            self.handlers.paymentStatusChange(paymentStatus: status.toApi())
        }
    }

    @available(iOS 14.0, *)
    public func terminal(_: Terminal, didChangeConnectionStatus status: ConnectionStatus) {
        DispatchQueue.main.async {
            self.handlers.connectionStatusChange(connectionStatus: status.toApi())
        }
    }
}
