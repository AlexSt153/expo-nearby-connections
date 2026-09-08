import Foundation

let REQUEST_CONNECTION_TIMEOUT: NSNumber = 30 // in seconds

protocol NearbyConnectionCallbackDelegate: AnyObject {
    func onPeerFound(fromPeerId peerId: String, fromPeerName name: String)
    func onPeerLost(fromPeerId peerId: String)
    func onInvitationReceived(fromPeerId peerId: String, fromPeerName name: String)
    func onConnected(fromPeerId peerId: String, fromPeerName name: String)
    func onDisconnected(fromPeerId peerId: String)
    func onTextReceived(fromPeerId peerId: String, payload text: String)
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
    )
    func onFileReceived(
        transferId: String,
        peerId: String,
        uri: String,
        name: String,
        mimeType: String?,
        size: Int64
    )
}
