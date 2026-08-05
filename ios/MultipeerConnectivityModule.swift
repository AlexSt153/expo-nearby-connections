import Foundation
import MultipeerConnectivity

public class MultipeerConnectivityModule: NSObject {
    private final class FileTransferRecord {
        let transferId: String
        let peerId: String
        let direction: String
        let progress: Progress
        var metadata: FileTransferMetadata?
        var observation: NSKeyValueObservation?
        var lastProgressEmitAt: TimeInterval = 0

        init(
            transferId: String,
            peerId: String,
            direction: String,
            progress: Progress,
            metadata: FileTransferMetadata?
        ) {
            self.transferId = transferId
            self.peerId = peerId
            self.direction = direction
            self.progress = progress
            self.metadata = metadata
        }
    }

    private struct IncomingMetadata {
        let peerId: String
        let metadata: FileTransferMetadata
    }

    private struct CompletedIncomingFile {
        let peerId: String
        let temporaryURL: URL
        let size: Int64
    }

    private struct OutgoingCompletion {
        let error: Error?
    }

    private struct IncomingTerminalKey: Hashable {
        let transferId: String
        let peerId: String
    }

    private var myPeerId: MCPeerID?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var discovery: MCNearbyServiceBrowser?
    private var session: MCSession?

    // MC callbacks fire on background queues while JS calls can arrive concurrently.
    private let peerQueue = DispatchQueue(label: "com.exponearbyconnections.peers")
    private var discoveredPeers: [String: MCPeerID] = [:]
    private var invitedPeers: [String: (peerId: MCPeerID, invitationHandler: (Bool, MCSession?) -> Void)] = [:]
    private var connectedPeers: [String: MCPeerID] = [:]

    private let fileQueue = DispatchQueue(label: "com.exponearbyconnections.files")
    private var outgoingFiles: [String: FileTransferRecord] = [:]
    private var registeringOutgoingTransfers: Set<String> = []
    private var pendingOutgoingCompletions: [String: OutgoingCompletion] = [:]
    private var incomingFiles: [String: FileTransferRecord] = [:]
    private var incomingMetadata: [String: IncomingMetadata] = [:]
    private var completedIncomingFiles: [String: CompletedIncomingFile] = [:]
    private var metadataTimeouts: [String: DispatchWorkItem] = [:]
    private var recentIncomingTerminals: Set<IncomingTerminalKey> = []

    weak var delegate: NearbyConnectionCallbackDelegate?

    deinit {
        self.advertiser?.stopAdvertisingPeer()
        self.discovery?.stopBrowsingForPeers()
        self.session?.disconnect()
    }

    public func startAdvertise(_ name: String) -> String {
        self.advertiser?.stopAdvertisingPeer()
        self.session?.disconnect()
        self.session = nil
        self.failAllFileTransfers("Session restarted")

        let peerId = MCPeerID(displayName: name)
        self.myPeerId = peerId
        let discoveryInfo: [String: String] = [
            "incomingPeerId": String(peerId.hash),
            "incomingName": name
        ]
        let serviceType = InfoPlistParser.getServiceType()

        self.advertiser = MCNearbyServiceAdvertiser(peer: peerId, discoveryInfo: discoveryInfo, serviceType: serviceType)
        self.advertiser?.delegate = self

        self.session = MCSession(peer: peerId, securityIdentity: nil, encryptionPreference: .required)
        self.session?.delegate = self

        self.advertiser?.startAdvertisingPeer()

        return String(peerId.hash)
    }

    public func stopAdvertise() {
        self.advertiser?.stopAdvertisingPeer()
        self.advertiser = nil
        peerQueue.sync { self.invitedPeers.removeAll() }
    }

    public func startDiscovery(_ name: String) -> String {
        self.discovery?.stopBrowsingForPeers()
        self.session?.disconnect()
        self.session = nil
        self.failAllFileTransfers("Session restarted")

        let peerId = MCPeerID(displayName: name)
        self.myPeerId = peerId
        let serviceType = InfoPlistParser.getServiceType()

        self.discovery = MCNearbyServiceBrowser(peer: peerId, serviceType: serviceType)
        self.discovery?.delegate = self

        self.session = MCSession(peer: peerId, securityIdentity: nil, encryptionPreference: .required)
        self.session?.delegate = self

        self.discovery?.startBrowsingForPeers()

        return String(peerId.hash)
    }

    public func stopDiscovery() {
        self.discovery?.stopBrowsingForPeers()
        self.discovery = nil
        peerQueue.sync { self.discoveredPeers.removeAll() }
    }

    public func requestConnection(to advertisePeerId: String) throws {
        guard let myPeerId = self.myPeerId else {
            throw moduleError("RequestConnection: Not found my peer.")
        }

        guard let session = self.session else {
            throw moduleError("RequestConnection: No active session. Call startDiscovery first.")
        }

        let contextObj: [String: String] = [
            "incomingName": myPeerId.displayName,
            "incomingPeerId": String(myPeerId.hash)
        ]
        let contextData = try? JSONSerialization.data(withJSONObject: contextObj)
        let timeout = TimeInterval(truncating: REQUEST_CONNECTION_TIMEOUT)

        let targetPeer = peerQueue.sync { self.discoveredPeers[advertisePeerId] }
        guard let targetPeerId = targetPeer else {
            throw moduleError("RequestConnection: Not found target peer.")
        }

        self.discovery?.invitePeer(targetPeerId, to: session, withContext: contextData, timeout: timeout)
    }

    public func acceptConnection(to peerId: String) throws {
        let invitedPeer = peerQueue.sync { self.invitedPeers.removeValue(forKey: peerId) }
        guard let invitedPeer = invitedPeer else {
            throw moduleError("AcceptConnection: Not found target peer.")
        }
        invitedPeer.invitationHandler(true, self.session)
    }

    public func rejectConnection(to peerId: String) throws {
        let invitedPeer = peerQueue.sync { self.invitedPeers.removeValue(forKey: peerId) }
        guard let invitedPeer = invitedPeer else {
            throw moduleError("RejectConnection: Not found target peer.")
        }
        invitedPeer.invitationHandler(false, self.session)
    }

    public func disconnect() {
        self.failAllFileTransfers("Session disconnected")
        self.advertiser?.stopAdvertisingPeer()
        self.advertiser = nil
        self.discovery?.stopBrowsingForPeers()
        self.discovery = nil
        self.session?.disconnect()
        self.session = nil
        peerQueue.sync {
            self.connectedPeers.removeAll()
            self.discoveredPeers.removeAll()
            self.invitedPeers.removeAll()
        }
    }

    public func sendText(to peerId: String, payload text: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw moduleError("SendText: Invalid text data.")
        }

        guard let session = self.session else {
            throw moduleError("SendText: No active session.")
        }

        let targetPeer = peerQueue.sync { self.connectedPeers[peerId] }
        guard let targetPeerId = targetPeer else {
            throw moduleError("SendText: Not found target peer.")
        }

        try session.send(data, toPeers: [targetPeerId], with: .reliable)
    }

    public func sendFile(
        to peerId: String,
        uri: String,
        name: String?,
        mimeType: String?
    ) throws -> String {
        guard let session = self.session else {
            throw moduleError("SendFile: No active session.")
        }

        let targetPeer = peerQueue.sync { self.connectedPeers[peerId] }
        guard let targetPeerId = targetPeer else {
            throw moduleError("SendFile: Not found target peer.")
        }

        let fileURL = try localFileURL(from: uri)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw moduleError("SendFile: File does not exist at \(fileURL.path).")
        }

        let transferId = UUID().uuidString
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let metadata = FileTransferMetadata(
            protocolIdentifier: "expo-nearby-connections/file-v1",
            transferId: transferId,
            name: FileTransferProtocol.sanitizeFileName(
                name?.isEmpty == false ? name : fileURL.lastPathComponent,
                transferId: transferId
            ),
            mimeType: mimeType?.isEmpty == false ? mimeType : nil,
            size: size
        )

        try session.send(
            FileTransferProtocol.encode(metadata),
            toPeers: [targetPeerId],
            with: .reliable
        )

        fileQueue.sync {
            self.registeringOutgoingTransfers.insert(transferId)
        }
        guard let progress = session.sendResource(
            at: fileURL,
            withName: transferId,
            toPeer: targetPeerId,
            withCompletionHandler: { [weak self] error in
                self?.handleOutgoingCompletion(transferId: transferId, error: error)
            }
        ) else {
            fileQueue.sync {
                self.registeringOutgoingTransfers.remove(transferId)
                self.pendingOutgoingCompletions.removeValue(forKey: transferId)
            }
            throw moduleError("SendFile: Multipeer Connectivity did not start the transfer.")
        }

        let record = FileTransferRecord(
            transferId: transferId,
            peerId: peerId,
            direction: Self.directionOutgoing,
            progress: progress,
            metadata: metadata
        )
        fileQueue.sync {
            self.registeringOutgoingTransfers.remove(transferId)
            self.outgoingFiles[transferId] = record
            self.observeProgress(record)
            if let completion = self.pendingOutgoingCompletions.removeValue(forKey: transferId) {
                self.finishOutgoingTransfer(record, error: completion.error)
            }
        }

        return transferId
    }

    public func cancelFileTransfer(_ transferId: String) throws {
        var cancelledRecord: FileTransferRecord?
        fileQueue.sync {
            cancelledRecord = self.outgoingFiles.removeValue(forKey: transferId)
                ?? self.incomingFiles.removeValue(forKey: transferId)
            if cancelledRecord == nil,
                let completed = self.completedIncomingFiles.removeValue(forKey: transferId) {
                let metadata = self.incomingMetadata[transferId]?.metadata
                let progress = Progress(totalUnitCount: max(completed.size, 0))
                progress.completedUnitCount = max(completed.size, 0)
                cancelledRecord = FileTransferRecord(
                    transferId: transferId,
                    peerId: completed.peerId,
                    direction: Self.directionIncoming,
                    progress: progress,
                    metadata: metadata
                )
                completed.temporaryURL
                    .deletingLastPathComponent()
                    .removeRecursivelyIfPresent()
            }
            cancelledRecord?.observation?.invalidate()
            cancelledRecord?.progress.cancel()
            self.metadataTimeouts.removeValue(forKey: transferId)?.cancel()
            self.incomingMetadata.removeValue(forKey: transferId)
            if let record = cancelledRecord, record.direction == Self.directionIncoming {
                _ = self.rememberIncomingTerminal(transferId, peerId: record.peerId)
            }
        }

        guard let record = cancelledRecord else {
            throw moduleError("CancelFileTransfer: Transfer not found.")
        }

        emitFileTransferUpdate(
            record: record,
            status: Self.statusCancelled,
            error: nil
        )
    }

    private func localFileURL(from rawValue: String) throws -> URL {
        if let parsed = URL(string: rawValue), parsed.isFileURL {
            return parsed
        }
        if !rawValue.contains("://") {
            return URL(fileURLWithPath: rawValue)
        }
        throw moduleError("SendFile: Unsupported URI. Use a file:// URI.")
    }

    private func handleFileMetadata(peerId: String, metadata: FileTransferMetadata) {
        fileQueue.async {
            let terminalKey = IncomingTerminalKey(
                transferId: metadata.transferId,
                peerId: peerId
            )
            guard !self.recentIncomingTerminals.contains(terminalKey) else { return }
            if let incoming = self.incomingFiles[metadata.transferId],
                incoming.peerId != peerId {
                return
            }
            if let completed = self.completedIncomingFiles[metadata.transferId],
                completed.peerId != peerId {
                return
            }

            self.incomingMetadata[metadata.transferId] = IncomingMetadata(
                peerId: peerId,
                metadata: metadata
            )
            self.incomingFiles[metadata.transferId]?.metadata = metadata
            self.metadataTimeouts.removeValue(forKey: metadata.transferId)?.cancel()
            self.finalizeIncomingFile(transferId: metadata.transferId)
            if self.incomingFiles[metadata.transferId] == nil,
                self.completedIncomingFiles[metadata.transferId] == nil {
                self.scheduleMetadataTimeout(transferId: metadata.transferId)
            }
        }
    }

    private func observeProgress(_ record: FileTransferRecord) {
        record.observation = record.progress.observe(
            \.fractionCompleted,
            options: [.initial, .new]
        ) { [weak self, weak record] _, _ in
            guard let self, let record else { return }
            self.fileQueue.async {
                guard self.outgoingFiles[record.transferId] === record
                    || self.incomingFiles[record.transferId] === record else {
                    return
                }
                self.emitProgressIfNeeded(record)
            }
        }
    }

    private func emitProgressIfNeeded(_ record: FileTransferRecord) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - record.lastProgressEmitAt >= Self.progressThrottleSeconds else {
            return
        }
        record.lastProgressEmitAt = now
        emitFileTransferUpdate(
            record: record,
            status: Self.statusInProgress,
            error: nil
        )
    }

    private func handleOutgoingCompletion(transferId: String, error: Error?) {
        fileQueue.async {
            guard let record = self.outgoingFiles[transferId] else {
                if self.registeringOutgoingTransfers.contains(transferId) {
                    self.pendingOutgoingCompletions[transferId] = OutgoingCompletion(error: error)
                }
                return
            }
            self.finishOutgoingTransfer(record, error: error)
        }
    }

    private func finishOutgoingTransfer(_ record: FileTransferRecord, error: Error?) {
        guard outgoingFiles.removeValue(forKey: record.transferId) != nil else { return }
        record.observation?.invalidate()

        let status: String
        if record.progress.isCancelled {
            status = Self.statusCancelled
        } else if error != nil {
            status = Self.statusFailed
        } else {
            status = Self.statusCompleted
        }

        emitFileTransferUpdate(
            record: record,
            status: status,
            error: error?.localizedDescription
        )
    }

    private func handleIncomingResourceStarted(
        transferId: String,
        peerId: String,
        progress: Progress
    ) {
        fileQueue.async {
            let terminalKey = IncomingTerminalKey(transferId: transferId, peerId: peerId)
            guard !self.recentIncomingTerminals.contains(terminalKey) else {
                progress.cancel()
                return
            }
            if let metadata = self.incomingMetadata[transferId], metadata.peerId != peerId {
                progress.cancel()
                return
            }
            self.metadataTimeouts.removeValue(forKey: transferId)?.cancel()
            let metadata = self.incomingMetadata[transferId]?.metadata
            let record = FileTransferRecord(
                transferId: transferId,
                peerId: peerId,
                direction: Self.directionIncoming,
                progress: progress,
                metadata: metadata
            )
            self.incomingFiles[transferId] = record
            self.observeProgress(record)
        }
    }

    private func handleIncomingResourceFinished(
        transferId: String,
        peerId: String,
        temporaryURL: URL?,
        error: Error?
    ) {
        var cachedURL: URL?
        var cacheError: Error?

        if error == nil, let temporaryURL {
            do {
                cachedURL = try moveIncomingFileToCache(
                    transferId: transferId,
                    temporaryURL: temporaryURL
                )
            } catch {
                cacheError = error
            }
        } else if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        fileQueue.async {
            guard let record = self.incomingFiles.removeValue(forKey: transferId) else {
                cachedURL?.deletingLastPathComponent().removeRecursivelyIfPresent()
                return
            }
            record.observation?.invalidate()

            if record.progress.isCancelled {
                cachedURL?.deletingLastPathComponent().removeRecursivelyIfPresent()
                _ = self.rememberIncomingTerminal(transferId, peerId: record.peerId)
                self.emitFileTransferUpdate(
                    record: record,
                    status: Self.statusCancelled,
                    error: nil
                )
                self.cleanupIncomingState(transferId)
                return
            }

            if let failure = error ?? cacheError {
                cachedURL?.deletingLastPathComponent().removeRecursivelyIfPresent()
                _ = self.rememberIncomingTerminal(transferId, peerId: record.peerId)
                self.emitFileTransferUpdate(
                    record: record,
                    status: Self.statusFailed,
                    error: failure.localizedDescription
                )
                self.cleanupIncomingState(transferId)
                return
            }

            guard let cachedURL else {
                _ = self.rememberIncomingTerminal(transferId, peerId: record.peerId)
                self.emitFileTransferUpdate(
                    record: record,
                    status: Self.statusFailed,
                    error: "Multipeer Connectivity returned no received file URL"
                )
                self.cleanupIncomingState(transferId)
                return
            }

            let size = ((try? FileManager.default.attributesOfItem(atPath: cachedURL.path)[.size]) as? NSNumber)?.int64Value ?? -1
            self.completedIncomingFiles[transferId] = CompletedIncomingFile(
                peerId: peerId,
                temporaryURL: cachedURL,
                size: size
            )
            self.finalizeIncomingFile(transferId: transferId)

            guard self.completedIncomingFiles[transferId] != nil else {
                return
            }

            self.scheduleMetadataTimeout(transferId: transferId)
        }
    }

    private func moveIncomingFileToCache(
        transferId: String,
        temporaryURL: URL
    ) throws -> URL {
        let cacheRoot = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let safeTransferId = FileTransferProtocol.sanitizeFileName(
            transferId,
            transferId: "transfer"
        )
        let transferDirectory = cacheRoot
            .appendingPathComponent("ExpoNearbyConnections", isDirectory: true)
            .appendingPathComponent(safeTransferId, isDirectory: true)
        try FileManager.default.createDirectory(
            at: transferDirectory,
            withIntermediateDirectories: true
        )

        let destination = transferDirectory.appendingPathComponent("payload.part")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        return destination
    }

    private func finalizeIncomingFile(transferId: String) {
        guard let completed = completedIncomingFiles[transferId] else { return }
        guard let metadata = incomingMetadata[transferId]?.metadata else { return }

        completedIncomingFiles.removeValue(forKey: transferId)
        metadataTimeouts.removeValue(forKey: transferId)?.cancel()

        let finalName = FileTransferProtocol.sanitizeFileName(
            metadata.name,
            transferId: transferId
        )
        let finalURL = completed.temporaryURL
            .deletingLastPathComponent()
            .appendingPathComponent(finalName)

        do {
            if completed.temporaryURL != finalURL {
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: completed.temporaryURL, to: finalURL)
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size]) as? NSNumber)?.int64Value ?? completed.size
            let completedProgress = Progress(totalUnitCount: max(size, 0))
            completedProgress.completedUnitCount = max(size, 0)
            let record = FileTransferRecord(
                transferId: transferId,
                peerId: completed.peerId,
                direction: Self.directionIncoming,
                progress: completedProgress,
                metadata: metadata
            )
            guard rememberIncomingTerminal(transferId, peerId: completed.peerId) else {
                finalURL.deletingLastPathComponent().removeRecursivelyIfPresent()
                cleanupIncomingState(transferId)
                return
            }
            emitFileTransferUpdate(
                record: record,
                status: Self.statusCompleted,
                error: nil
            )
            delegate?.onFileReceived(
                transferId: transferId,
                peerId: completed.peerId,
                uri: finalURL.absoluteString,
                name: finalName,
                mimeType: metadata.mimeType,
                size: size
            )
        } catch {
            completed.temporaryURL.deletingLastPathComponent().removeRecursivelyIfPresent()
            _ = rememberIncomingTerminal(transferId, peerId: completed.peerId)
            let failedProgress = Progress(totalUnitCount: max(completed.size, 0))
            let record = FileTransferRecord(
                transferId: transferId,
                peerId: completed.peerId,
                direction: Self.directionIncoming,
                progress: failedProgress,
                metadata: metadata
            )
            emitFileTransferUpdate(
                record: record,
                status: Self.statusFailed,
                error: error.localizedDescription
            )
        }

        cleanupIncomingState(transferId)
    }

    private func scheduleMetadataTimeout(transferId: String) {
        metadataTimeouts.removeValue(forKey: transferId)?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.failOrphanedIncomingTransfer(transferId: transferId)
        }
        metadataTimeouts[transferId] = timeout
        fileQueue.asyncAfter(
            deadline: .now() + Self.metadataTimeoutSeconds,
            execute: timeout
        )
    }

    private func failOrphanedIncomingTransfer(transferId: String) {
        let completed = completedIncomingFiles.removeValue(forKey: transferId)
        let metadata = incomingMetadata[transferId]
        guard completed != nil || (metadata != nil && incomingFiles[transferId] == nil) else {
            return
        }
        let peerId = completed?.peerId ?? metadata!.peerId
        let terminalKey = IncomingTerminalKey(transferId: transferId, peerId: peerId)
        guard !recentIncomingTerminals.contains(terminalKey) else {
            cleanupIncomingState(transferId)
            return
        }
        guard rememberIncomingTerminal(transferId, peerId: peerId) else { return }

        let size = completed?.size ?? 0
        let progress = Progress(totalUnitCount: max(size, 0))
        progress.completedUnitCount = max(size, 0)
        let record = FileTransferRecord(
            transferId: transferId,
            peerId: peerId,
            direction: Self.directionIncoming,
            progress: progress,
            metadata: metadata?.metadata
        )
        emitFileTransferUpdate(
            record: record,
            status: Self.statusFailed,
            error: completed == nil
                ? "File resource was not received"
                : "File metadata was not received"
        )
        completed?.temporaryURL.deletingLastPathComponent().removeRecursivelyIfPresent()
        cleanupIncomingState(transferId)
    }

    private func rememberIncomingTerminal(_ transferId: String, peerId: String) -> Bool {
        recentIncomingTerminals.insert(
            IncomingTerminalKey(transferId: transferId, peerId: peerId)
        ).inserted
    }

    private func emitFileTransferUpdate(
        record: FileTransferRecord,
        status: String,
        error: String?
    ) {
        let total = record.progress.totalUnitCount >= 0
            ? record.progress.totalUnitCount
            : record.metadata?.size
        delegate?.onFileTransferUpdate(
            transferId: record.transferId,
            peerId: record.peerId,
            direction: record.direction,
            status: status,
            bytesTransferred: max(record.progress.completedUnitCount, 0),
            totalBytes: total.flatMap { $0 >= 0 ? $0 : nil },
            name: record.metadata?.name,
            mimeType: record.metadata?.mimeType,
            error: error
        )
    }

    private func cleanupIncomingState(_ transferId: String) {
        incomingFiles.removeValue(forKey: transferId)?.observation?.invalidate()
        incomingMetadata.removeValue(forKey: transferId)
        completedIncomingFiles.removeValue(forKey: transferId)
        metadataTimeouts.removeValue(forKey: transferId)?.cancel()
    }

    private func failFileTransfers(for peerId: String, message: String) {
        fileQueue.async {
            let outgoing = self.outgoingFiles.values.filter { $0.peerId == peerId }
            let incoming = self.incomingFiles.values.filter { $0.peerId == peerId }

            for record in outgoing {
                self.outgoingFiles.removeValue(forKey: record.transferId)
                record.observation?.invalidate()
                record.progress.cancel()
                self.emitFileTransferUpdate(
                    record: record,
                    status: Self.statusFailed,
                    error: message
                )
            }
            for record in incoming {
                self.incomingFiles.removeValue(forKey: record.transferId)
                record.observation?.invalidate()
                record.progress.cancel()
                _ = self.rememberIncomingTerminal(record.transferId, peerId: peerId)
                self.emitFileTransferUpdate(
                    record: record,
                    status: Self.statusFailed,
                    error: message
                )
                self.cleanupIncomingState(record.transferId)
            }

            let completedIds = self.completedIncomingFiles
                .filter { $0.value.peerId == peerId }
                .map(\.key)
            for transferId in completedIds {
                if let completed = self.completedIncomingFiles[transferId] {
                    let progress = Progress(totalUnitCount: max(completed.size, 0))
                    progress.completedUnitCount = max(completed.size, 0)
                    let record = FileTransferRecord(
                        transferId: transferId,
                        peerId: completed.peerId,
                        direction: Self.directionIncoming,
                        progress: progress,
                        metadata: self.incomingMetadata[transferId]?.metadata
                    )
                    _ = self.rememberIncomingTerminal(transferId, peerId: peerId)
                    self.emitFileTransferUpdate(
                        record: record,
                        status: Self.statusFailed,
                        error: message
                    )
                    completed.temporaryURL
                        .deletingLastPathComponent()
                        .removeRecursivelyIfPresent()
                }
                self.cleanupIncomingState(transferId)
            }

            let metadataOnlyIds = self.incomingMetadata
                .filter {
                    $0.value.peerId == peerId
                        && self.incomingFiles[$0.key] == nil
                        && self.completedIncomingFiles[$0.key] == nil
                }
                .map(\.key)
            for transferId in metadataOnlyIds {
                if let metadata = self.incomingMetadata[transferId],
                    self.rememberIncomingTerminal(transferId, peerId: peerId) {
                    let progress = Progress(totalUnitCount: max(metadata.metadata.size, 0))
                    let record = FileTransferRecord(
                        transferId: transferId,
                        peerId: peerId,
                        direction: Self.directionIncoming,
                        progress: progress,
                        metadata: metadata.metadata
                    )
                    self.emitFileTransferUpdate(
                        record: record,
                        status: Self.statusFailed,
                        error: message
                    )
                }
                self.cleanupIncomingState(transferId)
            }

            self.fileQueue.asyncAfter(deadline: .now() + Self.callbackDrainGraceSeconds) {
                self.recentIncomingTerminals.removeAll { $0.peerId == peerId }
            }
        }
    }

    private func failAllFileTransfers(_ message: String) {
        var peerIds = peerQueue.sync { Set(self.connectedPeers.keys) }
        peerIds.formUnion(fileQueue.sync {
            Set(
                self.outgoingFiles.values.map(\.peerId)
                    + self.incomingFiles.values.map(\.peerId)
                    + self.completedIncomingFiles.values.map(\.peerId)
                    + self.incomingMetadata.values.map(\.peerId)
            )
        })
        peerIds.forEach { self.failFileTransfers(for: $0, message: message) }
    }

    private func moduleError(_ message: String) -> NSError {
        NSError(
            domain: "ExpoNearbyConnections",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static let directionIncoming = "incoming"
    private static let directionOutgoing = "outgoing"
    private static let statusInProgress = "in_progress"
    private static let statusCompleted = "completed"
    private static let statusCancelled = "cancelled"
    private static let statusFailed = "failed"
    private static let progressThrottleSeconds: TimeInterval = 0.1
    private static let metadataTimeoutSeconds: TimeInterval = 30
    private static let callbackDrainGraceSeconds: TimeInterval = 60
}

private extension URL {
    func removeRecursivelyIfPresent() {
        try? FileManager.default.removeItem(at: self)
    }
}

extension MultipeerConnectivityModule: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        print("Advertiser Events: didNotStartAdvertisingPeer", error)
    }

    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let peerIdHash = String(peerID.hash)
        peerQueue.sync {
            self.invitedPeers[peerIdHash] = (peerId: peerID, invitationHandler: invitationHandler)
        }
        self.delegate?.onInvitationReceived(fromPeerId: peerIdHash, fromPeerName: peerID.displayName)
    }
}

extension MultipeerConnectivityModule: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        print("Browser Events: didNotStartBrowsingForPeers", error)
    }

    public func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        let peerIdHash = String(peerID.hash)
        peerQueue.sync {
            self.discoveredPeers[peerIdHash] = peerID
        }
        self.delegate?.onPeerFound(fromPeerId: peerIdHash, fromPeerName: peerID.displayName)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let peerIdHash = String(peerID.hash)
        peerQueue.sync {
            self.discoveredPeers.removeValue(forKey: peerIdHash)
        }
        self.delegate?.onPeerLost(fromPeerId: peerIdHash)
    }
}

extension MultipeerConnectivityModule: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peerIdHash = String(peerID.hash)
        switch state {
        case .connected:
            peerQueue.sync {
                self.connectedPeers[peerIdHash] = peerID
            }
            self.delegate?.onConnected(fromPeerId: peerIdHash, fromPeerName: peerID.displayName)
        case .notConnected:
            peerQueue.sync {
                self.connectedPeers.removeValue(forKey: peerIdHash)
            }
            failFileTransfers(for: peerIdHash, message: "Peer disconnected")
            self.delegate?.onDisconnected(fromPeerId: peerIdHash)
        case .connecting:
            print("Session Events: connecting with peer \(peerID.displayName)")
        @unknown default:
            print("Session Events: unknown with peer \(peerID.displayName) and state \(state.rawValue)")
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let peerIdHash = String(peerID.hash)
        switch FileTransferProtocol.decode(data) {
        case .notControl:
            guard let text = String(bytes: data, encoding: .utf8) else {
                print("Session Events: received non-UTF8 data from \(peerID.displayName)")
                return
            }
            self.delegate?.onTextReceived(fromPeerId: peerIdHash, payload: text)
        case .metadata(let metadata):
            handleFileMetadata(peerId: peerIdHash, metadata: metadata)
        case .invalid(let reason):
            print("Session Events: ignoring invalid file control message: \(reason)")
        }
    }

    public func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {
        // Streams are not part of the public API yet.
    }

    public func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        handleIncomingResourceStarted(
            transferId: resourceName,
            peerId: String(peerID.hash),
            progress: progress
        )
    }

    public func session(
        _ session: MCSession,
        didReceiveCertificate certificate: [Any]?,
        fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        print("Session Events: didReceiveCertificate with peer \(peerID.displayName)")
        certificateHandler(true)
    }

    public func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {
        handleIncomingResourceFinished(
            transferId: resourceName,
            peerId: String(peerID.hash),
            temporaryURL: localURL,
            error: error
        )
    }
}
