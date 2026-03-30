@testable import MeOrThemCore

func runInputValidatorTests() {
    suite("InputValidator") {
        // Valid
        expect(InputValidator.isValidPingTarget("1.1.1.1"),            "IPv4 1.1.1.1")
        expect(InputValidator.isValidPingTarget("8.8.8.8"),            "IPv4 8.8.8.8")
        expect(InputValidator.isValidPingTarget("192.168.1.1"),        "private IPv4")
        expect(InputValidator.isValidPingTarget("2606:4700:4700::1111"), "IPv6")
        expect(InputValidator.isValidPingTarget("::1"),                 "IPv6 loopback")
        expect(InputValidator.isValidPingTarget("cloudflare.com"),     "hostname")
        expect(InputValidator.isValidPingTarget("one.one.one.one"),    "multi-label hostname")
        expect(InputValidator.isValidPingTarget("sub.domain.example.co.uk"), "deep hostname")

        // Injection attempts
        expect(!InputValidator.isValidPingTarget("1.1.1.1; rm -rf /"), "rejects semicolon injection")
        expect(!InputValidator.isValidPingTarget("host | cat /etc/passwd"), "rejects pipe")
        expect(!InputValidator.isValidPingTarget("host`whoami`"),       "rejects backtick")
        expect(!InputValidator.isValidPingTarget("$(echo bad)"),        "rejects $() expansion")
        expect(!InputValidator.isValidPingTarget("host\nrm -rf /"),     "rejects newline")
        expect(!InputValidator.isValidPingTarget("host & bad"),         "rejects ampersand")

        // Edge cases
        expect(!InputValidator.isValidPingTarget(""),                   "rejects empty")
        expect(!InputValidator.isValidPingTarget("   "),                "rejects whitespace-only")
        expect(!InputValidator.isValidPingTarget(String(repeating: "a", count: 254)), "rejects >253 chars")
        expect(!InputValidator.isValidPingTarget("999.999.999.999"),   "rejects invalid IPv4")
        expect(!InputValidator.isValidPingTarget("-host.com"),         "rejects leading-hyphen label")
    }
}
