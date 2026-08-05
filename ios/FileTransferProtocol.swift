import Foundation

struct FileTransferMetadata: Codable {
    let protocolIdentifier: String
    let transferId: String
    let name: String
    let mimeType: String?
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case protocolIdentifier = "protocol"
        case transferId
        case name
        case mimeType
        case size
    }
}

enum FileControlMessage {
    case notControl
    case metadata(FileTransferMetadata)
    case invalid(String)
}

enum FileTransferProtocol {
    private static let magic = Data([0x89, 0x45, 0x4E, 0x43, 0x46])
    private static let version: UInt8 = 1

    static func encode(_ metadata: FileTransferMetadata) throws -> Data {
        var data = magic
        data.append(version)
        data.append(try JSONEncoder().encode(metadata))
        return data
    }

    static func decode(_ data: Data) -> FileControlMessage {
        guard data.starts(with: magic) else {
            return .notControl
        }

        guard data.count > magic.count else {
            return .invalid("Missing control message version")
        }

        guard data[data.startIndex + magic.count] == version else {
            return .invalid("Unsupported file protocol version")
        }

        do {
            let jsonData = data.dropFirst(magic.count + 1)
            let decoded = try JSONDecoder().decode(
                FileTransferMetadata.self,
                from: Data(jsonData)
            )
            guard decoded.protocolIdentifier == "expo-nearby-connections/file-v1" else {
                return .invalid("Unsupported file protocol identifier")
            }

            return .metadata(
                FileTransferMetadata(
                    protocolIdentifier: decoded.protocolIdentifier,
                    transferId: decoded.transferId,
                    name: sanitizeFileName(decoded.name, transferId: decoded.transferId),
                    mimeType: decoded.mimeType?.isEmpty == false ? decoded.mimeType : nil,
                    size: decoded.size
                )
            )
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    static func sanitizeFileName(_ name: String?, transferId: String) -> String {
        let fallback = "received-\(transferId)"
        guard let name, !name.isEmpty else { return fallback }

        let lastComponent = URL(fileURLWithPath: name).lastPathComponent
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.controlCharacters)
        let sanitizedScalars = lastComponent.unicodeScalars.map { scalar in
            forbidden.contains(scalar) ? "_" : String(scalar)
        }
        let sanitized = String(sanitizedScalars.joined().prefix(180))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        return sanitized.isEmpty ? fallback : sanitized
    }
}
