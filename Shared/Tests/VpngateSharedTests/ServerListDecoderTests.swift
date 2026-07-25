import XCTest
@testable import VpngateShared

final class ServerListDecoderTests: XCTestCase {
    func testDecodesTypicalResponse() throws {
        let csv = """
        *vpn_servers\r
        #HostName,IP,Score,Ping,Speed,CountryLong,CountryShort,NumVpnSessions,Uptime,TotalUsers,TotalTraffic,LogType,Operator,Message,OpenVPN_ConfigData_Base64\r
        public-vpn-1.example.com,1.2.3.4,12345,42,1000000,Japan,JP,3,86400,100,1000,2days,someone@example.com,,c29tZS1jb25maWc=\r
        *\r

        """
        let servers = try ServerListDecoder.decode(csv: Data(csv.utf8))
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].hostName, "public-vpn-1.example.com")
        XCTAssertEqual(servers[0].countryLong, "Japan")
        XCTAssertEqual(servers[0].countryShort, "JP")
        XCTAssertEqual(servers[0].score, 12345)
        XCTAssertEqual(servers[0].ipAddr, "1.2.3.4")
        XCTAssertEqual(servers[0].openVpnConfigDataBase64, "c29tZS1jb25maWc=")
        XCTAssertEqual(servers[0].ping, "42")
    }

    func testStripsEmbeddedQuotes() throws {
        let csv = """
        *vpn_servers\r
        #HostName,IP,Score,Ping,CountryLong,CountryShort,OpenVPN_ConfigData_Base64\r
        "public-vpn-1.example.com","1.2.3.4","100","10","Japan","JP","c29tZQ=="\r
        *\r
        """
        let servers = try ServerListDecoder.decode(csv: Data(csv.utf8))
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].hostName, "public-vpn-1.example.com")
    }

    func testMissingHeaderThrows() {
        let csv = "not,a,header,row\r\nsome,data,here,too\r\n"
        XCTAssertThrowsError(try ServerListDecoder.decode(csv: Data(csv.utf8))) { error in
            XCTAssertEqual(error as? ServerListDecoderError, .missingHeader)
        }
    }

    func testEmptyResponseReturnsEmptyList() throws {
        let csv = "*vpn_servers\r\n*\r\n"
        let servers = try ServerListDecoder.decode(csv: Data(csv.utf8))
        XCTAssertEqual(servers, [])
    }

    func testColumnOrderIsIndependent() throws {
        // Same columns as testDecodesTypicalResponse but reordered -- the
        // decoder looks columns up by name, not position, since upstream
        // doesn't guarantee a fixed column order.
        let csv = """
        *vpn_servers\r
        OpenVPN_ConfigData_Base64,CountryShort,#HostName,CountryLong,Ping,IP,Score\r
        c29tZS1jb25maWc=,JP,public-vpn-1.example.com,Japan,42,1.2.3.4,12345\r
        *\r
        """
        let servers = try ServerListDecoder.decode(csv: Data(csv.utf8))
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].hostName, "public-vpn-1.example.com")
        XCTAssertEqual(servers[0].countryLong, "Japan")
        XCTAssertEqual(servers[0].countryShort, "JP")
        XCTAssertEqual(servers[0].score, 12345)
        XCTAssertEqual(servers[0].ipAddr, "1.2.3.4")
        XCTAssertEqual(servers[0].openVpnConfigDataBase64, "c29tZS1jb25maWc=")
        XCTAssertEqual(servers[0].ping, "42")
    }

    func testRowWithTooFewFieldsThrowsMalformedRow() {
        let csv = """
        *vpn_servers\r
        #HostName,IP,Score,Ping,CountryLong,CountryShort,OpenVPN_ConfigData_Base64\r
        public-vpn-1.example.com,1.2.3.4,12345\r
        *\r
        """
        XCTAssertThrowsError(try ServerListDecoder.decode(csv: Data(csv.utf8))) { error in
            XCTAssertEqual(error as? ServerListDecoderError, .malformedRow(1))
        }
    }

    func testNonNumericScoreThrowsMalformedRow() {
        let csv = """
        *vpn_servers\r
        #HostName,IP,Score,Ping,CountryLong,CountryShort,OpenVPN_ConfigData_Base64\r
        public-vpn-1.example.com,1.2.3.4,not-a-number,42,Japan,JP,c29tZQ==\r
        *\r
        """
        XCTAssertThrowsError(try ServerListDecoder.decode(csv: Data(csv.utf8))) { error in
            XCTAssertEqual(error as? ServerListDecoderError, .malformedRow(1))
        }
    }

    func testSecondMalformedRowReportsCorrectRowNumber() {
        let csv = """
        *vpn_servers\r
        #HostName,IP,Score,Ping,CountryLong,CountryShort,OpenVPN_ConfigData_Base64\r
        public-vpn-1.example.com,1.2.3.4,100,10,Japan,JP,c29tZQ==\r
        public-vpn-2.example.com,1.2.3.5,not-a-number,20,Japan,JP,c29tZQ==\r
        *\r
        """
        XCTAssertThrowsError(try ServerListDecoder.decode(csv: Data(csv.utf8))) { error in
            XCTAssertEqual(error as? ServerListDecoderError, .malformedRow(2))
        }
    }
}
