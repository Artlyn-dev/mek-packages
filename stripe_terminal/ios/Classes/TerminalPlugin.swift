@available(iOS 14.0, *)
import Flutter
import StripeTerminal
import UIKit

@available(iOS 14.0, *)
public class TerminalPlugin: NSObject, FlutterPlugin, TerminalPlatformApi {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = TerminalPlugin(registrar.messenger())
        setTerminalPlatformApiHandler(registrar.messenger(), instance)
        instance.onAttachedToEngine()
    }

    private let handlers: TerminalHandlersApi

    init(_ binaryMessenger: FlutterBinaryMessenger) {
        self.handlers = TerminalHandlersApi(binaryMessenger)
        self._discoverReadersController = DiscoverReadersControllerApi(binaryMessenger: binaryMessenger)
        self._readerDelegate = ReaderDelegatePlugin(handlers)
    }

    public func onAttachedToEngine() {
        self.setupDiscoverReaders()
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        if (Terminal.hasTokenProvider()) { self._clean() }

        self._discoverReadersController.removeHandler()
        removeTerminalPlatformApiHandler()
    }

    @available(iOS 14.0, *)
    func onInit(_ shouldPrintLogs: Bool) async throws {
        if Terminal.hasTokenProvider() {
            _clean()
            return
        }

        let delegate = TerminalDelegatePlugin(handlers)
        Terminal.setTokenProvider(delegate)
        Terminal.shared.delegate = delegate
        if (shouldPrintLogs) { Terminal.setLogListener { message in print(message) } }
    }

    @available(iOS 14.0, *)
    func onClearCachedCredentials() throws {
        Terminal.shared.clearCachedCredentials()
        self._clean();
    }

    private let _discoverReadersController: DiscoverReadersControllerApi
    private let _discoveryDelegate = DiscoveryDelegatePlugin()
    private var _readers: [Reader] { get {
        return _discoveryDelegate.readers
    } }
    private let _readerDelegate: ReaderDelegatePlugin

    @available(iOS 14.0, *)
    func onGetConnectionStatus() throws -> ConnectionStatusApi {
        return Terminal.shared.connectionStatus.toApi()
    }

    @available(iOS 14.0, *)
    func onSupportsReadersOfType(
        _ deviceType: DeviceTypeApi?,
        _ discoveryConfiguration: DiscoveryConfigurationApi
    ) throws -> Bool {
        let hostDiscoveryMethod = discoveryConfiguration.toHostDiscoveryMethod()
        guard let hostDiscoveryMethod else {
            return false
        }
        let hostDeviceType = deviceType?.toHost()
        guard let hostDeviceType else {
            return false
        }
        let result = Terminal.shared.supportsReaders(
            of: hostDeviceType,
            discoveryMethod: hostDiscoveryMethod,
            simulated: discoveryConfiguration.toHostSimulated()
        )
        do {
            try result.get()
            return true
        } catch {
            return false
        }
    }

    func setupDiscoverReaders() {
        _discoverReadersController.setHandler(
            _discoveryDelegate.onListen,
            _discoveryDelegate.onCancel
        )
    }

    @available(iOS 14.0, *)
    func onConnectReader(
        _ serialNumber: String,
        _ configuration: any ConnectionConfigurationApi
    ) async throws -> ReaderApi {
        let configuration = try configuration.toHost(_readerDelegate)
        if let configuration = configuration {
            do {
                 let reader = try await Terminal.shared.connectReader(
                     _findReader(serialNumber),
                     connectionConfig: configuration
                 )
                 return reader.toApi()
             } catch let error as NSError {
                 throw error.toPlatformError()
             }
        }
        throw PlatformError("", "Unsupported connection configuration")
    }

    @available(iOS 14.0, *)
    func onGetConnectedReader() throws -> ReaderApi? {
        return Terminal.shared.connectedReader?.toApi()
    }

    @available(iOS 14.0, *)
    func onCancelReaderReconnection() async throws {
        try await _readerDelegate.cancelReconnection()
    }

    @available(iOS 14.0, *)
    func onListLocations(_ endingBefore: String?, _ limit: Int?, _ startingAfter: String?) async throws -> [LocationApi] {
        let params = ListLocationsParametersBuilder()
            .setEndingBefore(endingBefore)
            .setStartingAfter(startingAfter)
        limit.apply { params.setLimit(UInt($0)) }
        do {
            return try await Terminal.shared.listLocations(parameters: params.build()).0.map { $0.toApi() }
        } catch let error as NSError {
            throw error.toPlatformError()
        }
    }

    @available(iOS 14.0, *)
    func onInstallAvailableUpdate() throws {
        Terminal.shared.installAvailableUpdate()
    }

    @available(iOS 14.0, *)
    func onCancelReaderUpdate() async throws {
        try await _readerDelegate.cancelUpdate()
    }

    @available(iOS 14.0, *)
    func onRebootReader() async throws {
        do {
            try await Terminal.shared.rebootReader()
        } catch let error as NSError {
            throw error.toPlatformError()
        }
    }

    @available(iOS 14.0, *)
    func onDisconnectReader() async throws {
        do {
            try await Terminal.shared.disconnectReader()
        } catch let error as NSError {
            throw error.toPlatformError()
        }
    }

    @available(iOS 14.0, *)
    func onSetSimulatorConfiguration(_ configuration: SimulatorConfigurationApi) throws {
        Terminal.shared.simulatorConfiguration.availableReaderUpdate = configuration.update.toHost()
        Terminal.shared.simulatorConfiguration.simulatedCard = configuration.simulatedCard.toHost()
        Terminal.shared.simulatorConfiguration.simulatedTipAmount = configuration.simulatedTipAmount?.nsNumberValue
    }
}
