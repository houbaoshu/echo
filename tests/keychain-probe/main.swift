// OS integration fixture. Uses a unique service and synthetic data only.
// SecKeychainCreate produces a legacy database without partition ACLs, so this
// must exercise the default keychain, exactly as KeychainSecretStore does.
import Foundation
import Security

func check(_ status: OSStatus, _ operation: String) {
    guard status == errSecSuccess else {
        print("FAIL: \(operation): OSStatus \(status)")
        exit(1)
    }
}

guard CommandLine.arguments.count == 3 else { exit(1) }
let mode = CommandLine.arguments[1]
let service = CommandLine.arguments[2]
guard service.hasPrefix("local.chiyan.keychain-regression.") else { exit(1) }
/// The probe exercises the legacy file keychain, and only this deprecated call turns off its
/// interaction prompts. The attribute silences that one deprecation and nothing else.
@diagnose(DeprecatedDeclaration, as: ignored)
func disableKeychainPrompts() -> OSStatus { SecKeychainSetUserInteractionAllowed(false) }
check(disableKeychainPrompts(), "disable test prompts")
let marker = Data("synthetic-keychain-regression-value".utf8)
var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: "test-only"
]
if mode == "create" {
    var item = query
    item[kSecValueData as String] = marker
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    check(SecItemAdd(item as CFDictionary, nil), "add synthetic item")
}
query[kSecReturnData as String] = true
query[kSecMatchLimit as String] = kSecMatchLimitOne
var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
if mode == "expect-denied" {
    guard status == errSecInteractionNotAllowed || status == errSecAuthFailed else {
        print("FAIL: expected authorization denial, got OSStatus \(status)")
        exit(1)
    }
    print("PASS: changed/unrelated code requires authorization (OSStatus \(status))")
} else {
    check(status, "read without authorization UI")
    guard result as? Data == marker else { exit(1) }
    #if SECOND_BUILD
    print("PASS: rebuilt program read synthetic item without authorization UI")
    #else
    print("PASS: original program read synthetic item without authorization UI")
    #endif
}
