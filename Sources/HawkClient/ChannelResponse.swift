//
//  ChannelResponse.swift
//  
//
//  Created by Xiaoxin Lu on 1/13/23.
//
import Foundation

class DateParser {
    private var formatter: ISO8601DateFormatter
    init() {
        formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [
            .withFullDate,
            .withFullTime,
            .withDashSeparatorInDate,
            .withFractionalSeconds]
    }
    
    func parse (fromStrDate date: String) -> Date? {
        return formatter.date(from: date)
    }
    
    static func parse (fromStrDate date: String) -> Date? {
        return DateParser().parse(fromStrDate: date)
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static let customISO8601 = custom {
        let container = try $0.singleValueContainer()
        let string = try container.decode(String.self)
        if let date = DateParser.parse(fromStrDate: string) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
    }
}

// MARK: - ChannelResponse
public struct ChannelResponse: Codable {
    public let connectURI, id: String
    public let expires: Date

    enum CodingKeys: String, CodingKey {
        case connectURI = "connectUri"
        case id, expires
    }
}
