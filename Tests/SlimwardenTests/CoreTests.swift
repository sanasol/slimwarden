import XCTest
@testable import SlimwardenCore

final class CoreTests: XCTestCase {
    func testTOTPRFC6238() {
        // RFC 6238 SHA1 vector, secret "12345678901234567890".
        let totp = TOTP("otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8")!
        XCTAssertEqual(totp.code(at: Date(timeIntervalSince1970: 59)), "94287082")
        XCTAssertEqual(totp.code(at: Date(timeIntervalSince1970: 1111111109)), "07081804")
    }

    func testArgon2idRFC9106() throws {
        // RFC 9106 Argon2id parameters without secret/ad; checks the binding works and is deterministic.
        let a = try Crypto.argon2id(password: Data("password".utf8), salt: Data("somesalt".utf8), iterations: 2, memoryKiB: 65536, parallelism: 1)
        XCTAssertEqual(a.map { String(format: "%02x", $0) }.joined(),
                       "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7")
    }

    func testEncStringRoundTrip() throws {
        let key = SymmetricKey64.random()
        let enc = try EncString.encrypt("hello", with: key)
        XCTAssertEqual(try EncString(enc.string).decryptString(with: key), "hello")
        XCTAssertThrowsError(try enc.decryptString(with: .random()))
    }

    func testDateParsing() {
        XCTAssertNotNil(BWDate.parse("2023-04-17T08:07:12.123456Z"))
        XCTAssertNotNil(BWDate.parse("2023-04-17T08:07:12Z"))
    }

    func testJSONBoolsStayBools() throws {
        let j = try JSON.parse(Data(#"{"a":true,"b":1,"c":1.5}"#.utf8))
        XCTAssertEqual(j["a"], .bool(true))
        XCTAssertEqual(j["b"], .int(1))
        XCTAssertEqual(j["c"], .double(1.5))
    }
}
