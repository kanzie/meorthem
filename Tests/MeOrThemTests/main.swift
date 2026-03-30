import Foundation

print("MeOrThem Test Suite")
print("═══════════════════════════════════════")

runPingParserTests()
runCircularBufferTests()
runMetricStatusTests()
runMetricStoreTests()
runInputValidatorTests()
runSpeedtestParserTests()

printSummary()
exit(_failCount > 0 ? 1 : 0)
