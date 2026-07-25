import Foundation

public enum ServerListDecoderError: Error, Equatable {
    case missingHeader
    case malformedRow(Int)
}

/// Parses vpngate.net's CSV server list. Mirrors pkg/vpn/list.go's
/// parseVpnList: strips the leading "*vpn_servers" marker line, the
/// trailing "*" marker line, and all embedded double quotes, then maps
/// each row onto Server by column name (order-independent, since the
/// upstream API doesn't guarantee column order).
public enum ServerListDecoder {
    private static let requiredColumns = [
        "#HostName", "CountryLong", "CountryShort", "Score", "IP", "OpenVPN_ConfigData_Base64", "Ping",
    ]

    public static func decode(csv: Data) throws -> [Server] {
        var text = String(decoding: csv, as: UTF8.self)
        if text.hasPrefix("*vpn_servers\r\n") {
            text.removeFirst("*vpn_servers\r\n".count)
        }
        if text.hasSuffix("*\r\n") {
            text.removeLast("*\r\n".count)
        } else if text.hasSuffix("*\r") {
            text.removeLast("*\r".count)
        }
        text = text.replacingOccurrences(of: "\"", with: "")

        let rawLines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let headerLine = rawLines.first else { return [] }
        let columns = headerLine.components(separatedBy: ",")

        var indices: [String: Int] = [:]
        for column in requiredColumns {
            guard let idx = columns.firstIndex(of: column) else {
                throw ServerListDecoderError.missingHeader
            }
            indices[column] = idx
        }

        var servers: [Server] = []
        for (rowNumber, line) in rawLines.dropFirst().enumerated() {
            let fields = line.components(separatedBy: ",")
            guard fields.count >= columns.count else {
                throw ServerListDecoderError.malformedRow(rowNumber + 1)
            }
            guard let score = Int(fields[indices["Score"]!]) else {
                throw ServerListDecoderError.malformedRow(rowNumber + 1)
            }
            servers.append(Server(
                hostName: fields[indices["#HostName"]!].trimmingCharacters(in: .whitespaces),
                countryLong: fields[indices["CountryLong"]!].trimmingCharacters(in: .whitespaces),
                countryShort: fields[indices["CountryShort"]!].trimmingCharacters(in: .whitespaces),
                score: score,
                ipAddr: fields[indices["IP"]!].trimmingCharacters(in: .whitespaces),
                openVpnConfigDataBase64: fields[indices["OpenVPN_ConfigData_Base64"]!],
                ping: fields[indices["Ping"]!].trimmingCharacters(in: .whitespaces)
            ))
        }
        return servers
    }
}
