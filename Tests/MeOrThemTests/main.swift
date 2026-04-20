import Foundation

print("MeOrThem Test Suite")
print("═══════════════════════════════════════")

runPingParserTests()
runCircularBufferTests()
runMetricStatusTests()
runMetricStoreTests()
runInputValidatorTests()
runSpeedtestParserTests()
runBugFixTests()
runConnectionHistoryTests()
runSQLiteStoreTests()
runDNSProberTests()
runNetworkInfoTests()
runNetworkSessionKeyTests()

printSummary()
exit(_failCount > 0 ? 1 : 0)
