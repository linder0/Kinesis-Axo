import Combine
import Foundation
import KinesisCore

struct FingerValidationRow: Codable, Identifiable {
    let finger: CalibratedFinger
    var counts: [String: Int]
    var id: String { finger.rawValue }
    var total: Int { counts.values.reduce(0, +) }
    var correct: Int { counts[finger.rawValue, default: 0] }
    var recall: Double { total > 0 ? Double(correct) / Double(total) : 0 }
}

struct FingerCalibrationProfile: Codable {
    let version: Int
    let band: String
    let hand: String
    let created: Date
    let sampleRate: Int
    let model: FingerBaselineModel
    let validation: [FingerValidationRow]
    var total: Int { validation.reduce(0) { $0 + $1.total } }
    var correct: Int { validation.reduce(0) { $0 + $1.correct } }
    var passed: Bool { validation.count == 6 && validation.allSatisfy { $0.total >= 8 && $0.recall >= 0.75 } }
    var isValid: Bool {
        version == 1 && sampleRate == 2048 && model.isValid && validation.count == 6
            && Set(validation.map(\.finger)).count == 6
            && validation.allSatisfy { $0.total == 12 && $0.counts.values.allSatisfy { $0 >= 0 } }
    }
}

/// Holds the existing EMG subscription. It never changes firmware models or routes actions.
@MainActor final class FingerCalibrationController: ObservableObject {
    enum Phase: Equatable { case idle, waiting, ready, preparing, capturing, complete, preview }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var problem: String?
    @Published private(set) var trialIndex = 0
    @Published private(set) var progress = 0.0
    @Published private(set) var countdown = 0
    @Published private(set) var liveRMS = Array(repeating: 0.0, count: 8)
    @Published private(set) var prediction: CalibratedFinger?
    @Published private(set) var profile: FingerCalibrationProfile?
    @Published private(set) var validatedThisConnection = false
    private(set) var trials: [FingerCalibrationTrial] = []
    private let model: BandModel
    private let defaults: UserDefaults
    private let clock: () -> Double
    private let owner = UUID()
    private let listenerKey = "finger-calibration"
    private var ownsSession = false
    private var timer: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var samples: [Double] = []
    private var windows: [FingerEMGFeatures] = []
    private var previousSequence: UInt64?
    private var previousTimestamp: UInt64?
    private var lastArrival = -Double.infinity
    private var phaseStarted = 0.0
    private var sessionBand = ""
    private var sessionHand = ""
    private var sessionConnection: String?
    private var invalidFrameCount = 0
    private var configuration: EMGConfiguration?
    private var previewOnly = false
    static let windowsPerTrial = 12
    static let plan: [(CalibratedFinger, Int)] = (0..<4).flatMap { repetition in
        let labels: [CalibratedFinger] = repetition == 3
            ? [.ring, .rest, .index, .little, .thumb, .middle]
            : CalibratedFinger.allCases
        return labels.map { ($0, repetition) }
    }
    var active: Bool { ownsSession }
    var label: CalibratedFinger { Self.plan[min(trialIndex, Self.plan.count - 1)].0 }
    var repetition: Int { Self.plan[min(trialIndex, Self.plan.count - 1)].1 }
    var canStart: Bool {
        model.live && model.handConfirmed && model.pendingHand == nil
            && !model.modelControlsUnavailable && model.rawRecordingURL == nil
    }
    var prompt: String {
        label == .rest ? "Let your whole hand relax on the desk."
            : "Gently press your \(label.rawValue) finger into the desk. Keep your wrist still and let the other fingers rest."
    }

    init(model: BandModel, defaults: UserDefaults = .standard,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.model = model; self.defaults = defaults; self.clock = clock
        loadProfile()
        model.$live.dropFirst().sink { [weak self] live in
            guard let self, !live else { return }
            self.validatedThisConnection = false
            if self.active { self.fail("The band disconnected. Reconnect and start a fresh calibration.") }
        }.store(in: &subscriptions)
        model.$selectedAddress.dropFirst().sink { [weak self] address in
            guard let self, address != self.sessionBand else { return }
            self.validatedThisConnection = false
            if self.active { self.fail("The selected band changed. Start a fresh calibration.") }
            self.profile = nil
        }.store(in: &subscriptions)
        model.$bandHand.dropFirst().sink { [weak self] hand in
            guard let self, hand.rawValue != self.sessionHand else { return }
            self.validatedThisConnection = false
            if self.active { self.fail("The wearing wrist changed. Start a fresh calibration.") }
            self.profile = nil
        }.store(in: &subscriptions)
    }

    func loadProfile() {
        let key = "fingerBaseline.v1.\(model.selectedAddress).\(model.bandHand.rawValue)"
        guard let data = defaults.data(forKey: key), data.count < 200_000,
              let saved = try? JSONDecoder().decode(FingerCalibrationProfile.self, from: data),
              saved.isValid, saved.band == model.selectedAddress, saved.hand == model.bandHand.rawValue else {
            profile = nil; return
        }
        profile = saved
    }

    func start(automaticallyTicks: Bool = true) {
        guard !active else { return }
        guard canStart else { problem = "Connect your band, confirm its wrist, and finish other recordings first."; return }
        trials = []; trialIndex = 0; validatedThisConnection = false
        begin(preview: false, automaticallyTicks: automaticallyTicks)
    }

    func startPreview(automaticallyTicks: Bool = true) {
        guard !active, canStart, validatedThisConnection, profile?.passed == true,
              profile?.band == model.selectedAddress, profile?.hand == model.bandHand.rawValue else { return }
        begin(preview: true, automaticallyTicks: automaticallyTicks)
    }

    private func begin(preview: Bool, automaticallyTicks: Bool) {
        do { try model.acquireModelRecording(owner) }
        catch { problem = error.localizedDescription; return }
        ownsSession = true; previewOnly = preview
        sessionBand = model.selectedAddress; sessionHand = model.bandHand.rawValue
        sessionConnection = model.sensorStream.currentConnectionID
        problem = nil; prediction = nil; progress = 0
        samples = []; windows = []; previousSequence = nil; previousTimestamp = nil
        lastArrival = -.infinity; configuration = nil
        invalidFrameCount = model.readings.invalidFrames
        phase = .waiting; phaseStarted = clock()
        model.rawEMGListeners[listenerKey] = { [weak self] batch, arrived in self?.receive(batch, at: arrived) }
        model.holdRawEMG(listenerKey, true)
        if automaticallyTicks {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    self?.tick()
                }
            }
        }
    }

    /// The user explicitly starts every repetition; no samples cross a cue boundary.
    func capture() {
        guard phase == .ready, active else { return }
        problem = nil; samples = []; windows = []; prediction = nil
        phase = .preparing; phaseStarted = clock(); countdown = 2; progress = 0
    }

    func tick() {
        guard active else { return }
        let now = clock()
        guard model.live, model.handConfirmed, model.selectedAddress == sessionBand,
              model.bandHand.rawValue == sessionHand,
              model.sensorStream.currentConnectionID == sessionConnection else {
            fail("The band connection or wrist changed. Start a fresh calibration."); return
        }
        if let error = model.rawEMGError { fail(error); return }
        if model.readings.invalidFrames != invalidFrameCount {
            fail("An EMG packet could not be read. Start again with a steady connection."); return
        }
        if let current = model.readings.configuration, let configuration, current != configuration {
            fail("The EMG format changed. Start a fresh calibration."); return
        }
        if phase == .waiting {
            if now - phaseStarted > 12 { fail("No usable EMG signal arrived. Check the band’s skin contact, then try again.") }
            return
        }
        guard model.rawEMGActive, now - lastArrival <= 1 else {
            fail("The EMG stream stopped. Check the connection and start again."); return
        }
        if phase == .preparing {
            countdown = max(0, Int(ceil(2 - (now - phaseStarted))))
            if now - phaseStarted >= 2 {
                samples = []; windows = []; phase = .capturing; phaseStarted = now
            }
        } else if phase == .capturing, now - phaseStarted > 6 {
            fail("Not enough continuous samples for this repetition. Start again.")
        }
    }

    func receive(_ batch: EMGBatch, at arrived: Double) {
        guard active else { return }
        guard arrived.isFinite, abs(clock() - arrived) <= 1,
              model.live, model.handConfirmed, model.selectedAddress == sessionBand,
              model.bandHand.rawValue == sessionHand,
              model.sensorStream.currentConnectionID == sessionConnection,
              let format = model.readings.configuration, format.isSupported else {
            fail("The EMG signal is stale or its format changed. Start again."); return
        }
        if let configuration, configuration != format { fail("The EMG format changed. Start again."); return }
        configuration = format
        if let previousSequence, let previousTimestamp {
            guard batch.sequence > previousSequence, batch.timestampUs > previousTimestamp else {
                fail("The EMG stream restarted. Start a fresh calibration."); return
            }
            if batch.sequence - previousSequence != 1
                || abs(Double(batch.timestampUs - previousTimestamp) - EMGBatch.durationUs) > 2 {
                // Keep completed repetitions, but never bridge a missing packet with a
                // feature window. The interrupted cue must be captured from the start.
                samples = []; windows = []; prediction = nil; progress = 0
                self.previousSequence = batch.sequence; self.previousTimestamp = batch.timestampUs
                lastArrival = arrived
                if phase != .waiting && phase != .preview { phase = .ready }
                problem = "An EMG packet was missed. Relax, then capture this repetition again."
                return
            }
        }
        previousSequence = batch.sequence; previousTimestamp = batch.timestampUs; lastArrival = arrived
        guard model.readings.invalidFrames == invalidFrameCount else {
            fail("An EMG packet could not be read. Please start again."); return
        }
        // Saturated electrodes cannot provide a useful personal baseline.
        guard batch.values.filter({ $0 == 0 || $0 == UInt16.max }).count < 8 else {
            fail("The signal is clipping. Adjust the band’s contact and start again."); return
        }
        if phase == .preparing { return }
        samples.append(contentsOf: batch.values.map(Double.init))
        let count = FingerEMGFeatures.sampleCount * FingerEMGFeatures.channelCount
        guard samples.count >= count else { return }
        let input = Array(samples.prefix(count)); samples.removeFirst(count)
        let features: FingerEMGFeatures
        do { features = try FingerEMGFeatures.extract(input) }
        catch { fail("The electrodes are not producing a usable signal. Check skin contact and start again."); return }
        liveRMS = features.rms
        switch phase {
        case .waiting:
            guard model.rawEMGActive else { return }
            phase = previewOnly ? .preview : .ready
        case .capturing:
            windows.append(features)
            progress = Double(windows.count) / Double(Self.windowsPerTrial)
            if windows.count == Self.windowsPerTrial { finishTrial() }
        case .preview:
            prediction = profile?.model.predict(features).label
        default: break
        }
    }

    private func finishTrial() {
        trials.append(FingerCalibrationTrial(label: label, repetition: repetition, windows: windows))
        windows = []; samples = []
        if trialIndex + 1 < Self.plan.count {
            trialIndex += 1; phase = .ready; progress = 0
        } else {
            do {
                let fitted = try FingerBaselineModel(training: trials.filter { $0.repetition < 3 })
                let rows = CalibratedFinger.allCases.map { finger in
                    var counts: [String: Int] = [:]
                    for trial in trials where trial.repetition == 3 && trial.label == finger {
                        for window in trial.windows {
                            let result = fitted.predict(window).label?.rawValue ?? "uncertain"
                            counts[result, default: 0] += 1
                        }
                    }
                    return FingerValidationRow(finger: finger, counts: counts)
                }
                let saved = FingerCalibrationProfile(version: 1, band: sessionBand, hand: sessionHand,
                    created: Date(), sampleRate: 2048, model: fitted, validation: rows)
                guard saved.isValid else { throw KinesisError(message: "Calibration did not produce a complete validation result.") }
                let data = try JSONEncoder().encode(saved)
                defaults.set(data, forKey: "fingerBaseline.v1.\(sessionBand).\(sessionHand)")
                profile = saved; validatedThisConnection = true
                stop(); phase = .complete
            } catch { fail(error.localizedDescription) }
        }
    }

    func stop() {
        timer?.cancel(); timer = nil
        if ownsSession {
            model.rawEMGListeners[listenerKey] = nil
            model.holdRawEMG(listenerKey, false)
            model.releaseModelRecording(owner)
        }
        ownsSession = false; samples = []; windows = []; prediction = nil
        phase = profile == nil ? .idle : .complete
        // Controls stay paused. The user can explicitly enable them in the band pane.
    }

    private func fail(_ message: String) {
        problem = message; validatedThisConnection = false; trials = []; stop()
    }
}
