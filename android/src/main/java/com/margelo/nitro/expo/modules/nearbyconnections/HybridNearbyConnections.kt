package com.margelo.nitro.expo.modules.nearbyconnections

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.provider.OpenableColumns
import android.util.Log
import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.margelo.nitro.NitroModules
import com.margelo.nitro.core.Promise
import expo.modules.nearbyconnections.getStrategy
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

@DoNotStrip
@Keep
class HybridNearbyConnections : HybridNearbyConnectionsSpec() {

    // region Event callbacks

    override var onPeerFound: ((peerId: String, name: String) -> Unit)? = null
    override var onPeerLost: ((peerId: String) -> Unit)? = null
    override var onInvitationReceived: ((peerId: String, name: String) -> Unit)? = null
    override var onConnected: ((peerId: String, name: String) -> Unit)? = null
    override var onDisconnected: ((peerId: String) -> Unit)? = null
    override var onTextReceived: ((peerId: String, text: String) -> Unit)? = null
    override var onFileTransferUpdate: ((
        transferId: String,
        peerId: String,
        direction: String,
        status: String,
        bytesTransferred: Double,
        totalBytes: Double?,
        name: String?,
        mimeType: String?,
        error: String?,
    ) -> Unit)? = null
    override var onFileReceived: ((
        transferId: String,
        peerId: String,
        uri: String,
        name: String,
        mimeType: String?,
        size: Double,
    ) -> Unit)? = null

    // endregion

    // region State

    private data class CreatedFilePayload(
        val payload: Payload,
        val descriptor: ParcelFileDescriptor?,
        val detectedName: String?,
        val detectedMimeType: String?,
        val size: Long,
    )

    private data class OutgoingFileTransfer(
        val peerId: String,
        val metadata: FileTransferMetadata,
        val descriptor: ParcelFileDescriptor?,
    )

    private data class IncomingFileTransfer(
        val peerId: String,
        val payload: Payload,
        val processing: AtomicBoolean = AtomicBoolean(false),
        val aborted: AtomicBoolean = AtomicBoolean(false),
        val terminalEmitted: AtomicBoolean = AtomicBoolean(false),
    )

    private data class IncomingFileMetadata(
        val peerId: String,
        val metadata: FileTransferMetadata,
    )

    private data class CompletedIncomingFile(
        val peerId: String,
        val temporaryFile: File,
        val size: Long,
    )

    private data class IncomingTerminalKey(
        val transferId: String,
        val peerId: String,
    )

    private var myPeerName: String = ""

    // These maps are accessed from JS, Nearby callback, and file-worker threads.
    private val initiatedPeers: MutableMap<String, String> = ConcurrentHashMap()
    private val outgoingFiles = ConcurrentHashMap<String, OutgoingFileTransfer>()
    private val incomingFiles = ConcurrentHashMap<String, IncomingFileTransfer>()
    private val incomingMetadata = ConcurrentHashMap<String, IncomingFileMetadata>()
    private val completedIncomingFiles = ConcurrentHashMap<String, CompletedIncomingFile>()
    private val readyIncomingFiles = ConcurrentHashMap.newKeySet<String>()
    private val finalizingIncomingFiles = ConcurrentHashMap.newKeySet<String>()
    private val recentIncomingTerminals = ConcurrentHashMap.newKeySet<IncomingTerminalKey>()
    private val metadataTimeouts = ConcurrentHashMap<String, ScheduledFuture<*>>()
    private val lastProgressEmitAt = ConcurrentHashMap<String, Long>()
    private val fileExecutor = ScheduledThreadPoolExecutor(2).apply {
        removeOnCancelPolicy = true
    }

    // endregion

    // region Nearby Connections client

    private val connectionsClient: ConnectionsClient by lazy {
        Nearby.getConnectionsClient(context)
    }

    private val context: Context
        get() = requireNotNull(NitroModules.applicationContext) {
            "React Application Context is null"
        }

    // endregion

    // region Methods

    override fun isPlayServicesAvailable(): Promise<Boolean> {
        val result = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context)
        return Promise.resolved(result == ConnectionResult.SUCCESS)
    }

    override fun startAdvertise(name: String, strategy: Strategy?): Promise<String> {
        myPeerName = name
        val serviceId = context.packageName
        val options = AdvertisingOptions.Builder()
            .setStrategy(getStrategy(strategy))
            .build()

        val promise = Promise<String>()
        connectionsClient.startAdvertising(name, serviceId, advertiseCallback, options)
            .addOnSuccessListener { promise.resolve(name) }
            .addOnFailureListener { promise.reject(it) }
        return promise
    }

    override fun stopAdvertise(): Promise<Unit> {
        connectionsClient.stopAdvertising()
        return Promise.resolved(Unit)
    }

    override fun startDiscovery(name: String, strategy: Strategy?): Promise<String> {
        myPeerName = name
        val serviceId = context.packageName
        val options = DiscoveryOptions.Builder()
            .setStrategy(getStrategy(strategy))
            .build()

        val promise = Promise<String>()
        connectionsClient.startDiscovery(serviceId, discoveryCallback, options)
            .addOnSuccessListener { promise.resolve(name) }
            .addOnFailureListener { promise.reject(it) }
        return promise
    }

    override fun stopDiscovery(): Promise<Unit> {
        connectionsClient.stopDiscovery()
        return Promise.resolved(Unit)
    }

    override fun requestConnection(advertisePeerId: String): Promise<Unit> {
        val promise = Promise<Unit>()
        connectionsClient.requestConnection(myPeerName, advertisePeerId, requestConnectionCallback)
            .addOnSuccessListener { promise.resolve(Unit) }
            .addOnFailureListener { promise.reject(it) }
        return promise
    }

    override fun acceptConnection(targetPeerId: String): Promise<Unit> {
        val promise = Promise<Unit>()
        connectionsClient.acceptConnection(targetPeerId, payloadCallback)
            .addOnSuccessListener { promise.resolve(Unit) }
            .addOnFailureListener { promise.reject(it) }
        return promise
    }

    override fun rejectConnection(targetPeerId: String): Promise<Unit> {
        val promise = Promise<Unit>()
        connectionsClient.rejectConnection(targetPeerId)
            .addOnSuccessListener { promise.resolve(Unit) }
            .addOnFailureListener { promise.reject(it) }
        return promise
    }

    override fun disconnect(targetPeerId: String?): Promise<Unit> {
        if (targetPeerId != null) {
            connectionsClient.disconnectFromEndpoint(targetPeerId)
            failTransfersForPeer(targetPeerId, "Peer disconnected")
        } else {
            connectionsClient.stopAllEndpoints()
            failAllTransfers("All peers disconnected")
        }
        return Promise.resolved(Unit)
    }

    override fun sendText(targetPeerId: String, text: String): Promise<Unit> {
        val promise = Promise<Unit>()
        connectionsClient.sendPayload(targetPeerId, Payload.fromBytes(text.toByteArray()))
            .addOnSuccessListener { promise.resolve(Unit) }
            .addOnFailureListener { promise.reject(it) }
        return promise
    }

    override fun sendFile(
        targetPeerId: String,
        uri: String,
        name: String?,
        mimeType: String?,
    ): Promise<String> {
        val promise = Promise<String>()
        var createdSource: CreatedFilePayload? = null

        try {
            val source = createFilePayload(uri)
            createdSource = source
            val transferId = source.payload.id.toString()
            val metadata = FileTransferMetadata(
                transferId = transferId,
                name = FileTransferProtocol.sanitizeFileName(
                    name?.takeIf { it.isNotBlank() } ?: source.detectedName,
                    transferId,
                ),
                mimeType = mimeType?.takeIf { it.isNotBlank() } ?: source.detectedMimeType,
                size = source.size,
            )
            val outgoing = OutgoingFileTransfer(targetPeerId, metadata, source.descriptor)
            outgoingFiles[transferId] = outgoing

            val metadataPayload = Payload.fromBytes(FileTransferProtocol.encode(metadata))
            connectionsClient.sendPayload(targetPeerId, metadataPayload)
                .addOnSuccessListener {
                    if (outgoingFiles[transferId] !== outgoing) {
                        promise.reject(IllegalStateException("File transfer was interrupted"))
                        return@addOnSuccessListener
                    }
                    connectionsClient.sendPayload(targetPeerId, source.payload)
                        .addOnSuccessListener {
                            if (outgoingFiles[transferId] === outgoing) {
                                promise.resolve(transferId)
                            } else {
                                promise.reject(IllegalStateException("File transfer was interrupted"))
                            }
                        }
                        .addOnFailureListener { error ->
                            failOutgoingTransfer(transferId, outgoing, error.message ?: "Unable to send file")
                            promise.reject(error)
                        }
                }
                .addOnFailureListener { error ->
                    failOutgoingTransfer(transferId, outgoing, error.message ?: "Unable to send file metadata")
                    promise.reject(error)
                }
        } catch (error: Exception) {
            try {
                createdSource?.descriptor?.close()
            } catch (closeError: Exception) {
                Log.w(TAG, "Unable to close file descriptor after send failure", closeError)
            }
            promise.reject(error)
        }

        return promise
    }

    override fun cancelFileTransfer(transferId: String): Promise<Unit> {
        val payloadId = transferId.toLongOrNull()
            ?: return Promise.rejected(IllegalArgumentException("Invalid Android transfer ID: $transferId"))

        val promise = Promise<Unit>()
        connectionsClient.cancelPayload(payloadId)
            .addOnSuccessListener {
                outgoingFiles[transferId]?.let { transfer ->
                    if (removeOutgoingTransfer(transferId, transfer)) {
                        emitFileTransferUpdate(
                            transferId,
                            transfer.peerId,
                            DIRECTION_OUTGOING,
                            STATUS_CANCELLED,
                            0L,
                            transfer.metadata.size,
                            transfer.metadata,
                            null,
                        )
                    }
                }
                incomingFiles[transferId]?.let { transfer ->
                    if (markIncomingTerminal(transferId, transfer)) {
                        transfer.aborted.set(true)
                        emitFileTransferUpdate(
                            transferId,
                            transfer.peerId,
                            DIRECTION_INCOMING,
                            STATUS_CANCELLED,
                            0L,
                            incomingMetadata[transferId]?.metadata?.size ?: -1L,
                            incomingMetadata[transferId]?.metadata,
                            null,
                        )
                        cleanupIncomingTransfer(transferId, transfer)
                    }
                }
                promise.resolve(Unit)
            }
            .addOnFailureListener { promise.reject(it) }
        return promise
    }

    // endregion

    // region File transfer

    private fun createFilePayload(rawUri: String): CreatedFilePayload {
        val uri = Uri.parse(rawUri)
        return when (uri.scheme?.lowercase()) {
            "content" -> createContentFilePayload(uri)
            "file" -> createJavaFilePayload(
                File(requireNotNull(uri.path) { "File URI has no path" }),
            )
            null -> createJavaFilePayload(File(rawUri))
            else -> throw IllegalArgumentException(
                "Unsupported file URI scheme: ${uri.scheme}. Use file:// or content://.",
            )
        }
    }

    private fun createJavaFilePayload(file: File): CreatedFilePayload {
        if (!file.isFile || !file.canRead()) {
            throw FileNotFoundException("File is not readable: ${file.path}")
        }

        return CreatedFilePayload(
            payload = Payload.fromFile(file),
            descriptor = null,
            detectedName = file.name,
            detectedMimeType = null,
            size = file.length(),
        )
    }

    private fun createContentFilePayload(uri: Uri): CreatedFilePayload {
        val descriptor = context.contentResolver.openFileDescriptor(uri, "r")
            ?: throw FileNotFoundException("Unable to open content URI: $uri")

        return try {
            var detectedName: String? = null
            var detectedSize = descriptor.statSize
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameColumn >= 0 && !cursor.isNull(nameColumn)) {
                        detectedName = cursor.getString(nameColumn)
                    }
                    if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) {
                        detectedSize = cursor.getLong(sizeColumn)
                    }
                }
            }

            CreatedFilePayload(
                payload = Payload.fromFile(descriptor),
                descriptor = descriptor,
                detectedName = detectedName ?: uri.lastPathSegment,
                detectedMimeType = context.contentResolver.getType(uri),
                size = detectedSize,
            )
        } catch (error: Exception) {
            descriptor.close()
            throw error
        }
    }

    private fun handleFileMetadata(peerId: String, metadata: FileTransferMetadata) {
        if (recentIncomingTerminals.contains(IncomingTerminalKey(metadata.transferId, peerId))) return

        val incoming = incomingFiles[metadata.transferId]
        val completed = completedIncomingFiles[metadata.transferId]
        val expectedPeerId = incoming?.peerId ?: completed?.peerId
        if (expectedPeerId != null && expectedPeerId != peerId) {
            Log.w(TAG, "Ignoring file metadata from unexpected peer $peerId")
            return
        }

        incomingMetadata[metadata.transferId] = IncomingFileMetadata(peerId, metadata)
        maybeFinalizeIncomingFile(metadata.transferId)
        if (!incomingFiles.containsKey(metadata.transferId) &&
            !completedIncomingFiles.containsKey(metadata.transferId)
        ) {
            metadataTimeouts.remove(metadata.transferId)?.cancel(false)
            metadataTimeouts[metadata.transferId] = fileExecutor.schedule(
                { failMetadataWithoutFile(metadata.transferId) },
                METADATA_TIMEOUT_SECONDS,
                TimeUnit.SECONDS,
            )
        }
    }

    private fun handleFileTransferUpdate(peerId: String, update: PayloadTransferUpdate) {
        val transferId = update.payloadId.toString()
        val outgoing = outgoingFiles[transferId]
        if (outgoing != null) {
            if (outgoing.peerId != peerId) return
            handleOutgoingFileUpdate(transferId, outgoing, update)
            return
        }

        val incoming = incomingFiles[transferId] ?: return
        if (incoming.peerId != peerId) return
        handleIncomingFileUpdate(transferId, incoming, update)
    }

    private fun handleOutgoingFileUpdate(
        transferId: String,
        transfer: OutgoingFileTransfer,
        update: PayloadTransferUpdate,
    ) {
        when (update.status) {
            PayloadTransferUpdate.Status.IN_PROGRESS -> {
                if (shouldEmitProgress(transferId)) {
                    emitFileTransferUpdate(
                        transferId,
                        transfer.peerId,
                        DIRECTION_OUTGOING,
                        STATUS_IN_PROGRESS,
                        update.bytesTransferred,
                        update.totalBytes,
                        transfer.metadata,
                        null,
                    )
                }
            }

            PayloadTransferUpdate.Status.SUCCESS -> {
                if (!removeOutgoingTransfer(transferId, transfer)) return
                emitFileTransferUpdate(
                    transferId,
                    transfer.peerId,
                    DIRECTION_OUTGOING,
                    STATUS_COMPLETED,
                    update.bytesTransferred,
                    update.totalBytes,
                    transfer.metadata,
                    null,
                )
            }

            PayloadTransferUpdate.Status.CANCELED -> {
                if (!removeOutgoingTransfer(transferId, transfer)) return
                emitFileTransferUpdate(
                    transferId,
                    transfer.peerId,
                    DIRECTION_OUTGOING,
                    STATUS_CANCELLED,
                    update.bytesTransferred,
                    update.totalBytes,
                    transfer.metadata,
                    null,
                )
            }

            PayloadTransferUpdate.Status.FAILURE -> {
                failOutgoingTransfer(transferId, transfer, "Nearby file transfer failed")
            }
        }
    }

    private fun handleIncomingFileUpdate(
        transferId: String,
        transfer: IncomingFileTransfer,
        update: PayloadTransferUpdate,
    ) {
        when (update.status) {
            PayloadTransferUpdate.Status.IN_PROGRESS -> {
                if (shouldEmitProgress(transferId)) {
                    emitFileTransferUpdate(
                        transferId,
                        transfer.peerId,
                        DIRECTION_INCOMING,
                        STATUS_IN_PROGRESS,
                        update.bytesTransferred,
                        update.totalBytes,
                        incomingMetadata[transferId]?.metadata,
                        null,
                    )
                }
            }

            PayloadTransferUpdate.Status.SUCCESS -> {
                if (transfer.processing.compareAndSet(false, true) && !transfer.aborted.get()) {
                    lastProgressEmitAt.remove(transferId)
                    fileExecutor.execute {
                        copyIncomingFileToCache(transferId, transfer, update.totalBytes)
                    }
                }
            }

            PayloadTransferUpdate.Status.CANCELED -> {
                if (markIncomingTerminal(transferId, transfer)) {
                    transfer.aborted.set(true)
                    emitFileTransferUpdate(
                        transferId,
                        transfer.peerId,
                        DIRECTION_INCOMING,
                        STATUS_CANCELLED,
                        update.bytesTransferred,
                        update.totalBytes,
                        incomingMetadata[transferId]?.metadata,
                        null,
                    )
                    cleanupIncomingTransfer(transferId, transfer)
                }
            }

            PayloadTransferUpdate.Status.FAILURE -> {
                if (markIncomingTerminal(transferId, transfer)) {
                    transfer.aborted.set(true)
                    emitFileTransferUpdate(
                        transferId,
                        transfer.peerId,
                        DIRECTION_INCOMING,
                        STATUS_FAILED,
                        update.bytesTransferred,
                        update.totalBytes,
                        incomingMetadata[transferId]?.metadata,
                        "Nearby file transfer failed",
                    )
                    cleanupIncomingTransfer(transferId, transfer)
                }
            }
        }
    }

    private fun copyIncomingFileToCache(
        transferId: String,
        transfer: IncomingFileTransfer,
        reportedSize: Long,
    ) {
        val transferDirectory = File(context.cacheDir, "ExpoNearbyConnections/$transferId")
        val temporaryFile = File(transferDirectory, "payload.part")
        var sourceUri: Uri? = null

        try {
            if (transfer.aborted.get()) return

            if (!transferDirectory.exists() && !transferDirectory.mkdirs()) {
                throw IllegalStateException("Unable to create transfer cache directory")
            }

            val payloadFile = transfer.payload.asFile()
                ?: throw IllegalStateException("Nearby payload did not contain a file")
            sourceUri = payloadFile.asUri()
            val input = context.contentResolver.openInputStream(sourceUri)
                ?: throw FileNotFoundException("Unable to open received Nearby file")

            input.use { source ->
                temporaryFile.outputStream().buffered().use { destination ->
                    source.copyTo(destination, DEFAULT_COPY_BUFFER_SIZE)
                }
            }

            if (transfer.aborted.get()) {
                temporaryFile.delete()
                transferDirectory.delete()
                return
            }

            val completed = CompletedIncomingFile(
                peerId = transfer.peerId,
                temporaryFile = temporaryFile,
                size = temporaryFile.length().takeIf { it >= 0L } ?: reportedSize,
            )
            completedIncomingFiles[transferId] = completed
            if (transfer.aborted.get() || incomingFiles[transferId] !== transfer) {
                completedIncomingFiles.remove(transferId, completed)
                transferDirectory.deleteRecursively()
                cleanupIncomingState(transferId)
                return
            }
            readyIncomingFiles.add(transferId)
            maybeFinalizeIncomingFile(transferId)
            fileExecutor.schedule(
                { failIncomingWithoutMetadata(transferId) },
                METADATA_TIMEOUT_SECONDS,
                TimeUnit.SECONDS,
            )
        } catch (error: Exception) {
            temporaryFile.delete()
            transferDirectory.delete()
            if (markIncomingTerminal(transferId, transfer)) {
                emitFileTransferUpdate(
                    transferId,
                    transfer.peerId,
                    DIRECTION_INCOMING,
                    STATUS_FAILED,
                    0L,
                    reportedSize,
                    incomingMetadata[transferId]?.metadata,
                    error.message ?: "Unable to store received file",
                )
            }
            cleanupIncomingState(transferId)
        } finally {
            sourceUri?.let { deleteNearbyTemporaryFile(it) }
        }
    }

    private fun maybeFinalizeIncomingFile(transferId: String) {
        if (!readyIncomingFiles.contains(transferId)) return
        val completed = completedIncomingFiles[transferId] ?: return
        val metadata = incomingMetadata[transferId]?.metadata ?: return
        val transfer = incomingFiles[transferId] ?: return
        if (!finalizingIncomingFiles.add(transferId)) return

        fileExecutor.execute {
            if (transfer.aborted.get()) {
                completed.temporaryFile.parentFile?.deleteRecursively()
                cleanupIncomingState(transferId)
                return@execute
            }
            val finalName = FileTransferProtocol.sanitizeFileName(
                metadata.name,
                transferId,
            )
            val finalFile = File(completed.temporaryFile.parentFile, finalName)

            try {
                if (completed.temporaryFile != finalFile &&
                    !completed.temporaryFile.renameTo(finalFile)
                ) {
                    completed.temporaryFile.copyTo(finalFile, overwrite = true)
                    completed.temporaryFile.delete()
                }

                val size = finalFile.length().takeIf { it >= 0L } ?: completed.size
                if (transfer.aborted.get() || !markIncomingTerminal(transferId, transfer)) {
                    finalFile.parentFile?.deleteRecursively()
                    return@execute
                }
                emitFileTransferUpdate(
                    transferId,
                    completed.peerId,
                    DIRECTION_INCOMING,
                    STATUS_COMPLETED,
                    size,
                    size,
                    metadata,
                    null,
                )
                onFileReceived?.invoke(
                    transferId,
                    completed.peerId,
                    Uri.fromFile(finalFile).toString(),
                    finalName,
                    metadata.mimeType,
                    size.toDouble(),
                )
            } catch (error: Exception) {
                if (markIncomingTerminal(transferId, transfer)) {
                    emitFileTransferUpdate(
                        transferId,
                        completed.peerId,
                        DIRECTION_INCOMING,
                        STATUS_FAILED,
                        0L,
                        completed.size,
                        metadata,
                        error.message ?: "Unable to finalize received file",
                    )
                }
                completed.temporaryFile.parentFile?.deleteRecursively()
            } finally {
                cleanupIncomingState(transferId)
            }
        }
    }

    private fun failIncomingWithoutMetadata(transferId: String) {
        val completed = completedIncomingFiles[transferId] ?: return
        val transfer = incomingFiles[transferId] ?: return
        if (incomingMetadata.containsKey(transferId)) return
        if (!markIncomingTerminal(transferId, transfer)) return
        transfer.aborted.set(true)

        emitFileTransferUpdate(
            transferId,
            completed.peerId,
            DIRECTION_INCOMING,
            STATUS_FAILED,
            completed.size,
            completed.size,
            null,
            "File metadata was not received",
        )
        completed.temporaryFile.parentFile?.deleteRecursively()
        cleanupIncomingState(transferId)
    }

    private fun failMetadataWithoutFile(transferId: String) {
        val metadata = incomingMetadata[transferId] ?: return
        if (incomingFiles.containsKey(transferId) || completedIncomingFiles.containsKey(transferId)) {
            return
        }
        if (!rememberIncomingTerminal(transferId, metadata.peerId)) return

        emitFileTransferUpdate(
            transferId,
            metadata.peerId,
            DIRECTION_INCOMING,
            STATUS_FAILED,
            0L,
            metadata.metadata.size,
            metadata.metadata,
            "File payload was not received",
        )
        cleanupIncomingState(transferId)
    }

    private fun markIncomingTerminal(
        transferId: String,
        transfer: IncomingFileTransfer,
    ): Boolean {
        if (!transfer.terminalEmitted.compareAndSet(false, true)) return false
        rememberIncomingTerminal(transferId, transfer.peerId)
        return true
    }

    private fun rememberIncomingTerminal(transferId: String, peerId: String): Boolean {
        return recentIncomingTerminals.add(IncomingTerminalKey(transferId, peerId))
    }

    private fun shouldEmitProgress(transferId: String): Boolean {
        val now = SystemClock.elapsedRealtime()
        val previous = lastProgressEmitAt[transferId] ?: 0L
        if (now - previous < PROGRESS_THROTTLE_MILLISECONDS) return false
        lastProgressEmitAt[transferId] = now
        return true
    }

    private fun emitFileTransferUpdate(
        transferId: String,
        peerId: String,
        direction: String,
        status: String,
        bytesTransferred: Long,
        totalBytes: Long,
        metadata: FileTransferMetadata?,
        error: String?,
    ) {
        onFileTransferUpdate?.invoke(
            transferId,
            peerId,
            direction,
            status,
            bytesTransferred.coerceAtLeast(0L).toDouble(),
            totalBytes.takeIf { it >= 0L }?.toDouble(),
            metadata?.name,
            metadata?.mimeType,
            error,
        )
    }

    private fun removeOutgoingTransfer(
        transferId: String,
        transfer: OutgoingFileTransfer,
    ): Boolean {
        if (!outgoingFiles.remove(transferId, transfer)) return false
        try {
            transfer.descriptor?.close()
        } catch (error: Exception) {
            Log.w(TAG, "Unable to close outgoing file descriptor", error)
        }
        lastProgressEmitAt.remove(transferId)
        return true
    }

    private fun failOutgoingTransfer(
        transferId: String,
        transfer: OutgoingFileTransfer,
        message: String,
    ) {
        if (!removeOutgoingTransfer(transferId, transfer)) return
        emitFileTransferUpdate(
            transferId,
            transfer.peerId,
            DIRECTION_OUTGOING,
            STATUS_FAILED,
            0L,
            transfer.metadata.size,
            transfer.metadata,
            message,
        )
    }

    private fun cleanupIncomingTransfer(
        transferId: String,
        transfer: IncomingFileTransfer,
    ) {
        val completedDirectory = completedIncomingFiles[transferId]
            ?.temporaryFile
            ?.parentFile
        fileExecutor.execute {
            try {
                transfer.payload.asFile()?.asUri()?.let { uri ->
                    deleteNearbyTemporaryFile(uri)
                }
            } catch (error: Exception) {
                Log.w(TAG, "Unable to delete incomplete Nearby file", error)
            }
            completedDirectory?.deleteRecursively()
        }
        cleanupIncomingState(transferId)
    }

    private fun deleteNearbyTemporaryFile(uri: Uri) {
        try {
            context.contentResolver.delete(uri, null, null)
        } catch (error: Exception) {
            Log.w(TAG, "Unable to delete Nearby temporary file", error)
        }
    }

    private fun cleanupIncomingState(transferId: String) {
        incomingFiles.remove(transferId)
        incomingMetadata.remove(transferId)
        completedIncomingFiles.remove(transferId)
        readyIncomingFiles.remove(transferId)
        finalizingIncomingFiles.remove(transferId)
        lastProgressEmitAt.remove(transferId)
        metadataTimeouts.remove(transferId)?.cancel(false)
    }

    private fun failTransfersForPeer(peerId: String, message: String) {
        outgoingFiles.entries
            .filter { it.value.peerId == peerId }
            .forEach { (transferId, transfer) ->
                failOutgoingTransfer(transferId, transfer, message)
            }

        incomingFiles.entries
            .filter { it.value.peerId == peerId }
            .forEach { (transferId, transfer) ->
                if (markIncomingTerminal(transferId, transfer)) {
                    transfer.aborted.set(true)
                    emitFileTransferUpdate(
                        transferId,
                        peerId,
                        DIRECTION_INCOMING,
                        STATUS_FAILED,
                        0L,
                        incomingMetadata[transferId]?.metadata?.size ?: -1L,
                        incomingMetadata[transferId]?.metadata,
                        message,
                    )
                    cleanupIncomingTransfer(transferId, transfer)
                }
            }

        completedIncomingFiles.entries
            .filter { it.value.peerId == peerId }
            .forEach { (transferId, completed) ->
                if (completedIncomingFiles.remove(transferId, completed)) {
                    completed.temporaryFile.parentFile?.deleteRecursively()
                    cleanupIncomingState(transferId)
                }
            }

        incomingMetadata.entries
            .filter {
                it.value.peerId == peerId &&
                    !incomingFiles.containsKey(it.key) &&
                    !completedIncomingFiles.containsKey(it.key)
            }
            .forEach { (transferId, entry) ->
                if (rememberIncomingTerminal(transferId, peerId)) {
                    emitFileTransferUpdate(
                        transferId,
                        peerId,
                        DIRECTION_INCOMING,
                        STATUS_FAILED,
                        0L,
                        entry.metadata.size,
                        entry.metadata,
                        message,
                    )
                }
                cleanupIncomingState(transferId)
            }

        fileExecutor.schedule(
            {
                recentIncomingTerminals.removeIf { it.peerId == peerId }
            },
            CALLBACK_DRAIN_GRACE_SECONDS,
            TimeUnit.SECONDS,
        )
    }

    private fun failAllTransfers(message: String) {
        val peerIds = buildSet {
            outgoingFiles.values.mapTo(this) { it.peerId }
            incomingFiles.values.mapTo(this) { it.peerId }
            completedIncomingFiles.values.mapTo(this) { it.peerId }
            incomingMetadata.values.mapTo(this) { it.peerId }
        }
        peerIds.forEach { failTransfersForPeer(it, message) }
    }

    // endregion

    // region Nearby Connections callbacks

    private val advertiseCallback: ConnectionLifecycleCallback =
        object : ConnectionLifecycleCallback() {
            override fun onConnectionResult(peerId: String, result: ConnectionResolution) {
                if (!result.status.isSuccess) {
                    Log.e(TAG, "Advertise connection failed for $peerId: ${result.status}")
                    return
                }
                val targetPeerName = initiatedPeers[peerId] ?: ""
                onConnected?.invoke(peerId, targetPeerName)
            }

            override fun onDisconnected(peerId: String) {
                failTransfersForPeer(peerId, "Peer disconnected")
                this@HybridNearbyConnections.onDisconnected?.invoke(peerId)
            }

            override fun onConnectionInitiated(peerId: String, connectionInfo: ConnectionInfo) {
                val peerName = connectionInfo.endpointName
                initiatedPeers[peerId] = peerName
                onInvitationReceived?.invoke(peerId, peerName)
            }
        }

    private val requestConnectionCallback: ConnectionLifecycleCallback =
        object : ConnectionLifecycleCallback() {
            override fun onConnectionResult(peerId: String, result: ConnectionResolution) {
                if (!result.status.isSuccess) {
                    Log.e(TAG, "Request connection failed for $peerId: ${result.status}")
                    return
                }
                val targetPeerName = initiatedPeers[peerId] ?: ""
                onConnected?.invoke(peerId, targetPeerName)
            }

            override fun onDisconnected(peerId: String) {
                failTransfersForPeer(peerId, "Peer disconnected")
                this@HybridNearbyConnections.onDisconnected?.invoke(peerId)
            }

            override fun onConnectionInitiated(peerId: String, connectionInfo: ConnectionInfo) {
                val peerName = connectionInfo.endpointName
                initiatedPeers[peerId] = peerName
                acceptConnection(peerId).catch { error ->
                    Log.e(TAG, "Auto-accept failed for $peerId", error)
                }
            }
        }

    private val discoveryCallback: EndpointDiscoveryCallback =
        object : EndpointDiscoveryCallback() {
            override fun onEndpointFound(peerId: String, info: DiscoveredEndpointInfo) {
                onPeerFound?.invoke(peerId, info.endpointName)
            }

            override fun onEndpointLost(peerId: String) {
                onPeerLost?.invoke(peerId)
            }
        }

    private val payloadCallback: PayloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(peerId: String, payload: Payload) {
            when (payload.type) {
                Payload.Type.BYTES -> {
                    val bytes = payload.asBytes() ?: return
                    when (val control = FileTransferProtocol.decode(bytes)) {
                        FileControlMessage.NotControl -> {
                            onTextReceived?.invoke(peerId, bytes.toString(Charsets.UTF_8))
                        }

                        is FileControlMessage.Metadata -> {
                            handleFileMetadata(peerId, control.value)
                        }

                        is FileControlMessage.Invalid -> {
                            Log.w(TAG, "Ignoring invalid file control message: ${control.reason}")
                        }
                    }
                }

                Payload.Type.FILE -> {
                    val transferId = payload.id.toString()
                    if (recentIncomingTerminals.contains(IncomingTerminalKey(transferId, peerId))) {
                        connectionsClient.cancelPayload(payload.id)
                        fileExecutor.execute {
                            payload.asFile()?.asUri()?.let(::deleteNearbyTemporaryFile)
                        }
                        return
                    }
                    val metadata = incomingMetadata[transferId]
                    if (metadata != null && metadata.peerId != peerId) {
                        Log.w(TAG, "Rejecting file payload from unexpected peer $peerId")
                        connectionsClient.cancelPayload(payload.id)
                        fileExecutor.execute {
                            payload.asFile()?.asUri()?.let(::deleteNearbyTemporaryFile)
                        }
                        return
                    }
                    metadataTimeouts.remove(transferId)?.cancel(false)
                    incomingFiles[transferId] = IncomingFileTransfer(peerId, payload)
                    emitFileTransferUpdate(
                        transferId,
                        peerId,
                        DIRECTION_INCOMING,
                        STATUS_IN_PROGRESS,
                        0L,
                        incomingMetadata[transferId]?.metadata?.size ?: -1L,
                        incomingMetadata[transferId]?.metadata,
                        null,
                    )
                }

                else -> Unit
            }
        }

        override fun onPayloadTransferUpdate(peerId: String, update: PayloadTransferUpdate) {
            handleFileTransferUpdate(peerId, update)
        }
    }

    // endregion

    companion object {
        private const val TAG = "HybridNearbyConnections"
        private const val DIRECTION_INCOMING = "incoming"
        private const val DIRECTION_OUTGOING = "outgoing"
        private const val STATUS_IN_PROGRESS = "in_progress"
        private const val STATUS_COMPLETED = "completed"
        private const val STATUS_CANCELLED = "cancelled"
        private const val STATUS_FAILED = "failed"
        private const val PROGRESS_THROTTLE_MILLISECONDS = 100L
        private const val METADATA_TIMEOUT_SECONDS = 30L
        private const val CALLBACK_DRAIN_GRACE_SECONDS = 60L
    }
}
