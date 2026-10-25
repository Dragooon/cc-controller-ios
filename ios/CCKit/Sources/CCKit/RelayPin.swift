import CryptoKit
import Foundation
import Security

public enum RelayPinError: Error, Sendable, Equatable, LocalizedError {
    case invalidFormat
    case unsupportedKey(type: String?, size: Int?)
    case invalidPublicKeyRepresentation
    case missingPublicKey
    case invalidCertificateChain

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: "Relay pin must be exactly 64 hexadecimal characters."
        case .unsupportedKey(let type, let size): "Unsupported certificate public key: type=\(type ?? "unknown"), size=\(size.map(String.init) ?? "unknown")."
        case .invalidPublicKeyRepresentation: "The EC public key was not an uncompressed P-256 point."
        case .missingPublicKey: "The certificate does not contain a public key."
        case .invalidCertificateChain: "The trust object does not contain a certificate chain."
        }
    }
}

public struct RelayPin: Sendable, Equatable, Hashable {
    public let value: String

    public init(_ value: String) throws {
        let normalized = value.lowercased()
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
              }) else {
            throw RelayPinError.invalidFormat
        }
        self.value = normalized
    }

    public static func spkiSHA256(of certificate: SecCertificate) throws -> String {
        guard let key = SecCertificateCopyKey(certificate) else {
            throw RelayPinError.missingPublicKey
        }
        guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any] else {
            throw RelayPinError.missingPublicKey
        }
        let type = attributes[kSecAttrKeyType] as? String
        let size = attributes[kSecAttrKeySizeInBits] as? Int
        guard type == (kSecAttrKeyTypeEC as String), size == 256 else {
            throw RelayPinError.unsupportedKey(type: type, size: size)
        }
        guard let external = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw RelayPinError.invalidPublicKeyRepresentation
        }
        guard external.count == 65, external.first == 0x04 else {
            throw RelayPinError.invalidPublicKeyRepresentation
        }

        let prefix = Data(hex: "3059301306072a8648ce3d020106082a8648ce3d030107034200")
        let digest = SHA256.hash(data: prefix + external)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public var check: String {
        value.prefix(8).uppercased().chunked(every: 4).joined(separator: " ")
    }

    public var grouped: String {
        value.chunked(every: 4).joined(separator: " ").uppercased()
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}

private extension String {
    func chunked(every size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: min(size, distance(from: start, to: endIndex)))
            return String(self[start..<end])
        }
    }
}
