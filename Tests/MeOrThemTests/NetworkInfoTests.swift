@testable import MeOrThemCore

func runNetworkInfoTests() {
    suite("NetworkInfo.parseRouteInfo") {
        // Typical WiFi output from /sbin/route -n get default
        let wifiOutput = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.1.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
         recvpipe  sendpipe  ssthresh  rtt,msec    rttvar  hopcount      mtu     expire
               0         0         0         0         0         0      1500         0
        """
        let (gw, iface) = NetworkInfo.parseRouteInfo(from: wifiOutput)
        expectEqual(gw,    "192.168.1.1", "WiFi: gateway IP parsed")
        expectEqual(iface, "en0",         "WiFi: interface parsed")

        // Ethernet on en1
        let ethernetOutput = """
            gateway: 10.0.0.1
          interface: en1
        """
        let (gw2, iface2) = NetworkInfo.parseRouteInfo(from: ethernetOutput)
        expectEqual(gw2,    "10.0.0.1", "Ethernet: gateway IP parsed")
        expectEqual(iface2, "en1",      "Ethernet: interface parsed")

        // VPN tunnel
        let vpnOutput = """
            gateway: 10.8.0.1
          interface: utun3
        """
        let (gw3, iface3) = NetworkInfo.parseRouteInfo(from: vpnOutput)
        expectEqual(gw3,    "10.8.0.1", "VPN: gateway IP parsed")
        expectEqual(iface3, "utun3",    "VPN: interface parsed")

        // PPP VPN
        let pppOutput = """
            gateway: 192.168.100.1
          interface: ppp0
        """
        let (gw4, iface4) = NetworkInfo.parseRouteInfo(from: pppOutput)
        expectEqual(gw4,    "192.168.100.1", "PPP: gateway IP parsed")
        expectEqual(iface4, "ppp0",          "PPP: interface parsed")

        // Only gateway present (no interface line — some VPN configs)
        let noIfaceOutput = "    gateway: 172.16.0.1\n"
        let (gw5, iface5) = NetworkInfo.parseRouteInfo(from: noIfaceOutput)
        expectEqual(gw5,   "172.16.0.1", "gateway-only: IP parsed")
        expectNil(iface5,                "gateway-only: interface is nil")

        // Empty output
        let (gw6, iface6) = NetworkInfo.parseRouteInfo(from: "")
        expectNil(gw6,    "empty output: gateway nil")
        expectNil(iface6, "empty output: interface nil")

        // Extra whitespace around values is stripped
        let spaceyOutput = "    gateway:   192.168.50.1   \n  interface:   en2   \n"
        let (gw7, iface7) = NetworkInfo.parseRouteInfo(from: spaceyOutput)
        expectEqual(gw7,    "192.168.50.1", "whitespace stripped from gateway")
        expectEqual(iface7, "en2",          "whitespace stripped from interface")
    }

    suite("NetworkInfo.parseMACFromARPOutput") {
        // Standard ARP hit
        let hit = "? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]"
        expectEqual(NetworkInfo.parseMACFromARPOutput(hit), "aa:bb:cc:dd:ee:ff",
                    "valid ARP line: MAC extracted")

        // ARP miss — incomplete entry
        let miss = "? (192.168.1.1) at (incomplete) on en0 ifscope [ethernet]"
        expectNil(NetworkInfo.parseMACFromARPOutput(miss),
                  "incomplete ARP entry returns nil")

        // No 'at' in output
        let noAt = "? (192.168.1.1) — no arp entry"
        expectNil(NetworkInfo.parseMACFromARPOutput(noAt),
                  "output without 'at' returns nil")

        // Empty string
        expectNil(NetworkInfo.parseMACFromARPOutput(""),
                  "empty output returns nil")

        // MAC without trailing 'on' segment (uncommon but valid)
        let noOn = "? (10.0.0.1) at 11:22:33:44:55:66"
        expectEqual(NetworkInfo.parseMACFromARPOutput(noOn), "11:22:33:44:55:66",
                    "MAC parsed when 'on' segment absent")

        // Multiline — only the first matching line is used
        let multi = """
        ? (192.168.1.2) at ff:ee:dd:cc:bb:aa on en0 ifscope [ethernet]
        ? (192.168.1.1) at 00:11:22:33:44:55 on en0 ifscope [ethernet]
        """
        expectEqual(NetworkInfo.parseMACFromARPOutput(multi), "ff:ee:dd:cc:bb:aa",
                    "multiline: first match returned")

        // Lowercase preservation
        let lower = "? (192.168.1.1) at AB:CD:EF:01:23:45 on en0 ifscope [ethernet]"
        expectEqual(NetworkInfo.parseMACFromARPOutput(lower), "AB:CD:EF:01:23:45",
                    "MAC case is preserved as-is from arp output")
    }
}
