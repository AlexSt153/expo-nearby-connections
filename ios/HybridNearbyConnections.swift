import NitroModules

public class HybridNearbyConnections: HybridNearbyConnectionsSpec_base, HybridNearbyConnectionsSpec_protocol {

    private var multipeerModule = MultipeerConnectivityModule()

    // MARK: - Event callbacks

    public var onPeerFound: ((_ peerId: String, _ name: String) -> Void)?
    public var onPeerLost: ((_ peerId: String) -> Void)?
    public var onInvitationReceived: ((_ peerId: String, _ name: String) -> Void)?
    public var onConnected: ((_ peerId: String, _ name: String) -> Void)?
    public var onDisconnected: ((_ peerId: String) -> Void)?
    public var onTextReceived: ((_ peerId: String, _ text: String) -> Void)?
    public var onFileTransferUpdate: ((
        _ transferId: String,
        _ peerId: String,
        _ direction: String,
        _ status: String,
        _ bytesTransferred: Double,
        _ totalBytes: Double?,
        _ name: String?,
        _ mimeType: String?,
        _ error: String?
    ) -> Void)?
    public var onFileReceived: ((
        _ transferId: String,
        _ peerId: String,
        _ uri: String,
        _ name: String,
        _ mimeType: String?,
        _ size: Double
    ) -> Void)?

    public override init() {
        super.init()
        multipeerModule.delegate = self
    }

    // MARK: - Methods

    public func isPlayServicesAvailable() throws -> Promise<Bool> {
        return Promise.resolved(withResult: true)
    }

    public func startAdvertise(name: String, strategy: Strategy?) throws -> Promise<String> {
        // strategy is ignored on iOS — MultipeerConnectivity has no equivalent concept
        let peerId = multipeerModule.startAdvertise(name)
        return Promise.resolved(withResult: peerId)
    }

    public func stopAdvertise() throws -> Promise<Void> {
        multipeerModule.stopAdvertise()
        return Promise.resolved()
    }

    public func startDiscovery(name: String, strategy: Strategy?) throws -> Promise<String> {
        // strategy is ignored on iOS — MultipeerConnectivity has no equivalent concept
        let peerId = multipeerModule.startDiscovery(name)
        return Promise.resolved(withResult: peerId)
    }

    public func stopDiscovery() throws -> Promise<Void> {
        multipeerModule.stopDiscovery()
        return Promise.resolved()
    }

    public func requestConnection(advertisePeerId: String) throws -> Promise<Void> {
        try multipeerModule.requestConnection(to: advertisePeerId)
        return Promise.resolved()
    }

    public func acceptConnection(targetPeerId: String) throws -> Promise<Void> {
        try multipeerModule.acceptConnection(to: targetPeerId)
        return Promise.resolved()
    }

    public func rejectConnection(targetPeerId: String) throws -> Promise<Void> {
        try multipeerModule.rejectConnection(to: targetPeerId)
        return Promise.resolved()
    }

    public func disconnect(targetPeerId: String?) throws -> Promise<Void> {
        // targetPeerId is ignored on iOS — MultipeerConnectivity disconnects the entire session
        multipeerModule.disconnect()
        return Promise.resolved()
    }

    public func sendText(targetPeerId: String, text: String) throws -> Promise<Void> {
        try multipeerModule.sendText(to: targetPeerId, payload: text)
        return Promise.resolved()
    }

    public func sendFile(
        targetPeerId: String,
        uri: String,
        name: String?,
        mimeType: String?
    ) throws -> Promise<String> {
        let transferId = try multipeerModule.sendFile(
            to: targetPeerId,
            uri: uri,
            name: name,
            mimeType: mimeType
        )
        return Promise.resolved(withResult: transferId)
    }

    public func cancelFileTransfer(transferId: String) throws -> Promise<Void> {
        try multipeerModule.cancelFileTransfer(transferId)
        return Promise.resolved()
    }
}

// MARK: - NearbyConnectionCallbackDelegate

extension HybridNearbyConnections: NearbyConnectionCallbackDelegate {
    func onPeerFound(fromPeerId peerId: String, fromPeerName name: String) {
        self.onPeerFound?(peerId, name)
    }

    func onPeerLost(fromPeerId peerId: String) {
        self.onPeerLost?(peerId)
    }

    func onInvitationReceived(fromPeerId peerId: String, fromPeerName name: String) {
        self.onInvitationReceived?(peerId, name)
    }

    func onConnected(fromPeerId peerId: String, fromPeerName name: String) {
        self.onConnected?(peerId, name)
    }

    func onDisconnected(fromPeerId peerId: String) {
        self.onDisconnected?(peerId)
    }

    func onTextReceived(fromPeerId peerId: String, payload text: String) {
        self.onTextReceived?(peerId, text)
    }

    func onFileTransferUpdate(
        transferId: String,
        peerId: String,
        direction: String,
        status: String,
        bytesTransferred: Int64,
        totalBytes: Int64?,
        name: String?,
        mimeType: String?,
        error: String?
    ) {
        self.onFileTransferUpdate?(
            transferId,
            peerId,
            direction,
            status,
            Double(bytesTransferred),
            totalBytes.map(Double.init),
            name,
            mimeType,
            error
        )
    }

    func onFileReceived(
        transferId: String,
        peerId: String,
        uri: String,
        name: String,
        mimeType: String?,
        size: Int64
    ) {
        self.onFileReceived?(
            transferId,
            peerId,
            uri,
            name,
            mimeType,
            Double(size)
        )
    }
}
