import Foundation
import Testing
@testable import KinesisCore
@testable import Kinesis

@MainActor private final class FingerRig {
    let defaults = MemoryDefaults()
    let connection = RecordedConnection()
    let controls = RecordingControls()
    let model: BandModel
    var now = 100.0
    var sequence: UInt64 = 0
    lazy var calibration = FingerCalibrationController(model: model, defaults: defaults, clock: { [unowned self] in now })

    init() throws {
        defaults.set(true, forKey: "setupCompleted")
        model = BandModel(defaults: defaults, connection: connection, controls: controls,
                          sessionStore: SavedSessionStore(), clock: { 100 })
        model.selectedAddress = "finger-test-band"
        model.connect()
        connection.send(.connected); connection.send(.heartbeat); connection.send(.handedness(.right))
        connection.send(.rawEMGConfiguration(try readingsConfiguration()))
    }

    func start() {
        calibration.start(automaticallyTicks: false)
        connection.send(.rawEMGState(true))
    }

    func feed(_ batches: Int = 32) {
        for _ in 0..<batches {
            connection.send(.rawEMGFrame(readingsPayload(sequence: sequence)), at: now)
            sequence += 1
            now += 1.0 / 128
        }
    }

    func close() async { calibration.stop(); await model.shutdown() }
}

@Suite("Finger calibration session", .serialized)
@MainActor struct FingerCalibrationControllerTests {
    @Test func sessionPausesControlsWithoutChangingModelsOrOpeningANetworkFeed() async throws {
        let rig = try FingerRig()
        rig.model.toggleControls()
        let mappings = rig.model.tapMappings
        rig.start(); rig.feed()
        #expect(rig.calibration.phase == .ready)
        #expect(rig.model.rawEMGHolders.contains("finger-calibration"))
        #expect(!rig.model.controlsEnabled && !rig.model.sensorStreamEnabled)
        #expect(rig.model.modelRecordingOwner != nil)
        rig.model.toggleControls()
        #expect(!rig.model.controlsEnabled)
        #expect(rig.connection.modelCaptureRequests.isEmpty)
        #expect(rig.model.tapMappings == mappings)
        rig.calibration.stop()
        #expect(!rig.model.rawEMGHolders.contains("finger-calibration"))
        #expect(rig.model.modelRecordingOwner == nil && !rig.model.controlsEnabled)
        #expect(rig.model.rawEMGListeners["finger-calibration"] == nil)
        await rig.close()
    }

    @Test func noSamplesCrossThePreparationCueAndHeldOutRoundIsSeparate() async throws {
        let rig = try FingerRig()
        rig.start(); rig.feed()
        rig.calibration.capture()
        rig.feed(64) // Resting data during the cue must not become labeled training data.
        #expect(rig.calibration.phase == .preparing && rig.calibration.trials.isEmpty)
        rig.now += 1.5; rig.feed(1); rig.calibration.tick()
        #expect(rig.calibration.phase == .capturing)
        rig.feed(32 * 12)
        #expect(rig.calibration.trials.count == 1)
        #expect(rig.calibration.trials.first?.label == .rest)
        #expect(rig.calibration.trials.first?.windows.count == 12)
        #expect(rig.calibration.label == .thumb && rig.calibration.phase == .ready)
        #expect(FingerCalibrationController.plan.filter { $0.1 == 3 }.count == 6)
        #expect(FingerCalibrationController.plan.filter { $0.1 < 3 }.count == 18)
        #expect(!rig.defaults.contents.keys.contains { $0.hasPrefix("fingerBaseline") })
        await rig.close()
    }

    @Test func aGapDiscardsTheIncompleteRepetitionAndRequiresANewCapture() async throws {
        let rig = try FingerRig()
        rig.start(); rig.feed()
        rig.calibration.capture(); rig.now += 2; rig.feed(1); rig.calibration.tick()
        rig.sequence += 1; rig.feed(1)
        #expect(rig.calibration.active && rig.calibration.phase == .ready)
        #expect(rig.calibration.problem != nil && rig.calibration.trials.isEmpty)
        #expect(!rig.calibration.validatedThisConnection)
        #expect(!rig.defaults.contents.keys.contains { $0.hasPrefix("fingerBaseline") })
        rig.calibration.stop()
        #expect(rig.model.modelRecordingOwner == nil)
        await rig.close()
    }

    @Test func aSequenceRestartAbortsRatherThanJoiningDifferentStreams() async throws {
        let rig = try FingerRig()
        rig.start(); rig.feed()
        rig.sequence = 0; rig.feed(1)
        #expect(!rig.calibration.active && rig.calibration.problem != nil)
        #expect(rig.model.modelRecordingOwner == nil)
        await rig.close()
    }

    @Test func disconnectAndStaleStreamsClearPredictionsAndNeverSaveAPartialProfile() async throws {
        let rig = try FingerRig()
        rig.start(); rig.feed()
        rig.connection.send(.disconnected)
        #expect(!rig.calibration.active && rig.calibration.prediction == nil)
        #expect(rig.model.modelRecordingOwner == nil)
        #expect(!rig.defaults.contents.keys.contains { $0.hasPrefix("fingerBaseline") })
        await rig.close()
        let stale = try FingerRig()
        stale.start(); stale.feed(); stale.now += 2; stale.calibration.tick()
        #expect(!stale.calibration.active && stale.calibration.problem != nil)
        await stale.close()
    }

    @Test func badFormatAndClippedInputAreNotAccepted() async throws {
        let rig = try FingerRig()
        rig.start(); rig.feed()
        rig.connection.send(.rawEMGConfiguration(try readingsConfiguration(encoding: 1)))
        rig.calibration.tick()
        #expect(!rig.calibration.active && rig.calibration.problem != nil)
        await rig.close()
        let clipped = try FingerRig()
        clipped.start()
        let payload = BandWire.field(1, 0) + BandWire.field(2, 1_000_000)
            + BandWire.field(3, Data(repeating: 255, count: 256))
        clipped.connection.send(.rawEMGFrame(payload), at: clipped.now)
        #expect(!clipped.calibration.active && clipped.calibration.problem?.contains("clipping") == true)
        await clipped.close()
    }

    @Test func calibrationIsUnavailableWithoutAConfirmedWristOrWhileAnotherOperationOwnsTheBand() async throws {
        let rig = try FingerRig()
        let other = UUID()
        try rig.model.acquireModelRecording(other)
        rig.start()
        #expect(!rig.calibration.active && rig.model.modelRecordingOwner == other)
        rig.model.releaseModelRecording(other)
        rig.connection.send(.handednessFailure("test failure"))
        rig.start()
        #expect(!rig.calibration.active)
        #expect(rig.calibration.problem != nil)
        await rig.close()
    }

    @Test func aCompleteRunSavesAnHonestHeldOutReportLocallyAndReloadRequiresValidation() async throws {
        let rig = try FingerRig()
        rig.start(); rig.feed()
        for _ in 0..<24 {
            #expect(rig.calibration.phase == .ready)
            rig.calibration.capture()
            rig.now += 2
            rig.feed(1); rig.calibration.tick()
            rig.feed(32 * 12)
        }
        let profile = try #require(rig.calibration.profile)
        #expect(rig.calibration.phase == .complete && !rig.calibration.active)
        #expect(profile.isValid && profile.total == 72)
        #expect(profile.validation.count == 6 && profile.validation.allSatisfy { $0.total == 12 })
        #expect(profile.band == "finger-test-band" && profile.hand == "right")
        #expect(rig.calibration.trials.filter { $0.repetition < 3 }.count == 18)
        #expect(rig.calibration.trials.filter { $0.repetition == 3 }.count == 6)
        #expect(rig.model.modelRecordingOwner == nil && !rig.model.controlsEnabled)
        let loaded = FingerCalibrationController(model: rig.model, defaults: rig.defaults)
        #expect(loaded.profile?.total == 72 && !loaded.validatedThisConnection)
        loaded.startPreview(automaticallyTicks: false)
        #expect(!loaded.active)
        rig.connection.send(.disconnected)
        #expect(!rig.calibration.validatedThisConnection)
        await rig.close()
    }
}
