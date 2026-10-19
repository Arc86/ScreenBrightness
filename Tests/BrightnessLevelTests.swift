import Testing

@Suite struct BrightnessLevelTests {
    @Test(arguments: [(-20.0, 0), (0, 0), (55.4, 55), (55.5, 56), (100, 100), (130, 100)])
    func hardwareValue(level: Double, expected: Int) {
        #expect(BrightnessLevel.hardwareValue(for: level) == expected)
    }

    @Test func dimFactorIsFullAboveZero() {
        #expect(BrightnessLevel.dimFactor(for: 0) == 1)
        #expect(BrightnessLevel.dimFactor(for: 40) == 1)
    }

    @Test func dimFactorFallsLinearlyToTheFloor() {
        #expect(abs(BrightnessLevel.dimFactor(for: -25) - 0.6) < 0.0001)
        #expect(abs(BrightnessLevel.dimFactor(for: BrightnessLevel.extraDimFloor) - BrightnessLevel.floorDimFactor) < 0.0001)
        #expect(abs(BrightnessLevel.dimFactor(for: -500) - BrightnessLevel.floorDimFactor) < 0.0001, "never darker than the floor")
    }

    @Test func stepsSnapToTheGrid() {
        let step = BrightnessLevel.keyStep
        #expect(BrightnessLevel.stepped(from: 13, direction: .up, step: step) == 18.75)
        #expect(BrightnessLevel.stepped(from: 0, direction: .down, step: step) == -6.25)
        #expect(BrightnessLevel.stepped(from: 50, direction: .up, step: step) == 56.25)
    }
}
