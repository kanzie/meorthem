@testable import MeOrThemCore

func runPingParserTests() {
    suite("PingParser") {
        let normal = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes
        64 bytes from 1.1.1.1: icmp_seq=0 ttl=55 time=12.345 ms
        64 bytes from 1.1.1.1: icmp_seq=1 ttl=55 time=11.234 ms
        64 bytes from 1.1.1.1: icmp_seq=2 ttl=55 time=13.456 ms
        64 bytes from 1.1.1.1: icmp_seq=3 ttl=55 time=10.987 ms
        64 bytes from 1.1.1.1: icmp_seq=4 ttl=55 time=12.001 ms

        --- 1.1.1.1 ping statistics ---
        5 packets transmitted, 5 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 10.987/12.005/13.456/0.812 ms
        """
        let r = PingParser.parse(normal)
        expectEqual(r.rtts.count, 5, "5 RTT samples parsed")
        expectEqual(r.lossPercent, 0.0, "0% loss")
        expect(abs(r.rtts[0] - 12.345) < 0.001, "first RTT is 12.345")

        let loss100 = """
        PING 192.0.2.1 (192.0.2.1): 56 data bytes
        Request timeout for icmp_seq 0
        --- 192.0.2.1 ping statistics ---
        5 packets transmitted, 0 packets received, 100.0% packet loss
        """
        let r2 = PingParser.parse(loss100)
        expectEqual(r2.rtts.count, 0, "no RTTs on 100% loss")
        expectEqual(r2.lossPercent, 100.0, "100% loss")

        let partial = """
        PING 8.8.8.8 (8.8.8.8): 56 data bytes
        64 bytes from 8.8.8.8: icmp_seq=0 ttl=55 time=20.0 ms
        Request timeout for icmp_seq 1
        64 bytes from 8.8.8.8: icmp_seq=2 ttl=55 time=22.0 ms
        --- 8.8.8.8 ping statistics ---
        5 packets transmitted, 2 packets received, 40.0% packet loss
        """
        let r3 = PingParser.parse(partial)
        expectEqual(r3.rtts.count, 2, "2 RTTs on partial loss")
        expectEqual(r3.lossPercent, 40.0, "40% loss")

        let empty = PingParser.parse("")
        expectEqual(empty.rtts.count, 0, "empty output: 0 RTTs")
        expectEqual(empty.lossPercent, 100.0, "empty output: 100% loss")
    }
}
