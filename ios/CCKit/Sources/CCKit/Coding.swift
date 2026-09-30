import Foundation

public enum CCDateCoding {
    public static let decoder: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let date = parse(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(value)")
        }
        return date
    }

    public static let encoder: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(format(date))
    }

    public static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public extension JSONDecoder {
    static func ccKit() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = CCDateCoding.decoder
        return decoder
    }
}

public extension JSONEncoder {
    static func ccKit() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = CCDateCoding.encoder
        return encoder
    }
}
