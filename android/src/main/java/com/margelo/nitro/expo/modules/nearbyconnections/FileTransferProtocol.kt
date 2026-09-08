package com.margelo.nitro.expo.modules.nearbyconnections

import org.json.JSONObject
import java.io.File

internal data class FileTransferMetadata(
    val transferId: String,
    val name: String,
    val mimeType: String?,
    val size: Long,
)

internal sealed interface FileControlMessage {
    data object NotControl : FileControlMessage
    data class Metadata(val value: FileTransferMetadata) : FileControlMessage
    data class Invalid(val reason: String) : FileControlMessage
}

internal object FileTransferProtocol {
    private val magic = byteArrayOf(0x89.toByte(), 0x45, 0x4E, 0x43, 0x46)
    private const val version: Byte = 1

    fun encode(metadata: FileTransferMetadata): ByteArray {
        val json = JSONObject()
            .put("protocol", "expo-nearby-connections/file-v1")
            .put("transferId", metadata.transferId)
            .put("name", metadata.name)
            .put("size", metadata.size)

        if (metadata.mimeType != null) {
            json.put("mimeType", metadata.mimeType)
        }

        return magic + byteArrayOf(version) + json.toString().toByteArray(Charsets.UTF_8)
    }

    fun decode(bytes: ByteArray): FileControlMessage {
        if (!bytes.startsWith(magic)) {
            return FileControlMessage.NotControl
        }

        if (bytes.size <= magic.size) {
            return FileControlMessage.Invalid("Missing control message version")
        }

        if (bytes[magic.size] != version) {
            return FileControlMessage.Invalid("Unsupported file protocol version")
        }

        return try {
            val json = JSONObject(
                bytes.copyOfRange(magic.size + 1, bytes.size).toString(Charsets.UTF_8),
            )
            val protocol = json.optString("protocol")
            if (protocol != "expo-nearby-connections/file-v1") {
                FileControlMessage.Invalid("Unsupported file protocol identifier")
            } else {
                val transferId = json.getString("transferId")
                val name = sanitizeFileName(json.getString("name"), transferId)
                val mimeType = json.optString("mimeType").takeIf { it.isNotBlank() }
                val size = json.optLong("size", -1L)
                FileControlMessage.Metadata(
                    FileTransferMetadata(transferId, name, mimeType, size),
                )
            }
        } catch (error: Exception) {
            FileControlMessage.Invalid(error.message ?: "Invalid file metadata")
        }
    }

    fun sanitizeFileName(name: String?, transferId: String): String {
        val baseName = name
            ?.let(::File)
            ?.name
            ?.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001F]"), "_")
            ?.trim()
            ?.trim('.')
            ?.take(180)
            .orEmpty()

        return baseName.ifBlank { "received-$transferId" }
    }

    private fun ByteArray.startsWith(prefix: ByteArray): Boolean {
        if (size < prefix.size) return false
        return prefix.indices.all { index -> this[index] == prefix[index] }
    }
}
