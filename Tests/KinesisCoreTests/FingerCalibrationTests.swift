import Foundation
import Testing
@testable import KinesisCore

@Suite("Finger EMG baseline calibration")
struct FingerCalibrationTests {
    private let channels = FingerEMGFeatures.channelCount
    private let samples = FingerEMGFeatures.sampleCount

    /// Per-class per-channel amplitude patterns (order follows
    /// `CalibratedFinger.allCases`: rest, thumb, index, middle, ring, little).
    private let patterns: [[Double]] = [
        [0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.6, 0.5],   // rest
        [2.2, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3],   // thumb
        [0.3, 2.4, 2.0, 0.4, 0.4, 0.4, 0.4, 0.3],   // index
        [0.3, 0.3, 0.3, 2.6, 2.2, 0.4, 0.3, 0.3],   // middle
        [0.4, 0.3, 0.3, 0.4, 0.4, 2.7, 2.1, 0.4],   // ring
        [0.3, 0.3, 0.3, 0.3, 0.3, 0.4, 0.4, 2.9],   // little
    ]

    private static func classIndex(_ label: CalibratedFinger) -> Int {
        CalibratedFinger.allCases.firstIndex(of: label)!
    }

    /// Generates one interleaved window for a class with a chosen DC offset.
    private func window(_ label: CalibratedFinger, offset: Double = 30_000,
                        gain: Double = 500, noise: Double = 0) -> FingerEMGFeatures {
        let idx = Self.classIndex(label)
        let pattern = patterns[idx]
        var interleaved = [Double](repeating: 0, count: samples * channels)
        let phaseScale = 2 * Double.pi * 3.7 / Double(samples)
        for s in 0..<samples {
            for c in 0..<channels {
                let freq = 1.0 + Double(c) * 0.11
                let noiseTerm = noise * Double.random(in: -1...1)
                let value = offset + pattern[c] * gain * (sin(phaseScale * Double(s) * freq) + noiseTerm)
                interleaved[s * channels + c] = value
            }
        }
        return try! FingerEMGFeatures.extract(interleaved)
    }

    /// Builds a calibration dataset with distinct synthetic classes.
    private func trainingSet(_ patternFor: ((CalibratedFinger) -> CalibratedFinger)? = nil,
                             windowsPerTrial: Int = 12) -> [FingerCalibrationTrial] {
        var trials = [FingerCalibrationTrial]()
        for label in CalibratedFinger.allCases {
            for rep in 0...2 {
                let source = patternFor?(label) ?? label
                let windows = (0..<windowsPerTrial).map { _ in window(source) }
                trials.append(FingerCalibrationTrial(label: label, repetition: rep, windows: windows))
            }
        }
        return trials
    }

    private func model(_ trials: [FingerCalibrationTrial]) throws -> FingerBaselineModel {
        try FingerBaselineModel(training: trials)
    }

    // MARK: - Extraction

    @Test func anExactUniqueCentroidMatchIsRecognized() throws {
        let fitted = try model(trainingSet())
        let features = window(.thumb)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fitted)) as? [String: Any])
        let mean = try #require(json["featureMean"] as? [Double])
        let scale = try #require(json["featureScale"] as? [Double])
        var centroids = try #require(json["centroids"] as? [[Double]])
        let vector = features.rms.map { log1p($0) } + features.waveformLengths.map { log1p($0) }
        centroids[Self.classIndex(.thumb)] = vector.indices.map { (vector[$0] - mean[$0]) / scale[$0] }
        json["centroids"] = centroids
        let exact = try JSONDecoder().decode(FingerBaselineModel.self, from: JSONSerialization.data(withJSONObject: json))
        let result = exact.predict(features)
        #expect(result.distance == 0 && result.margin == 1 && result.label == .thumb)
    }

    @Test func oversizedTrialsAreRejectedInsteadOfSilentlyTruncated() {
        var trials = trainingSet()
        trials[0] = FingerCalibrationTrial(label: .rest, repetition: 0, windows: Array(repeating: window(.rest), count: 129))
        #expect(throws: FingerBaselineModel.ModelError.invalidWindow) { _ = try model(trials) }
    }

    @Test func extractionRejectsWrongShapeAndNonfiniteInputs() {
        #expect(throws: FingerEMGFeatures.ExtractionError.wrongShape) {
            _ = try FingerEMGFeatures.extract([1, 2, 3])
        }
        var interleaved = [Double](repeating: 30_000, count: samples * channels)
        interleaved[0] = .nan
        #expect(throws: FingerEMGFeatures.ExtractionError.nonfinite) {
            _ = try FingerEMGFeatures.extract(interleaved)
        }
        var above = [Double](repeating: 0, count: samples * channels)
        above[3] = Double(UInt16.max) + 1
        above[10] = 123
        #expect(throws: FingerEMGFeatures.ExtractionError.outOfUInt16Range) {
            _ = try FingerEMGFeatures.extract(above)
        }
        var below = [Double](repeating: 0, count: samples * channels)
        below[5] = -1
        #expect(throws: FingerEMGFeatures.ExtractionError.outOfUInt16Range) {
            _ = try FingerEMGFeatures.extract(below)
        }
    }

    @Test func extractionRejectsFlatAllChannelSignal() {
        // Same constant on every channel of every sample: zero amplitude.
        let flat = [Double](repeating: 42_000, count: samples * channels)
        #expect(throws: FingerEMGFeatures.ExtractionError.flatSignal) {
            _ = try FingerEMGFeatures.extract(flat)
        }
    }

    @Test func extractionIsDCInvariantAndKeepsPerChannelStats() throws {
        let a = window(.index, offset: 30_000)
        let b = window(.index, offset: 60_000) // different DC offset
        #expect(zip(a.rms, b.rms).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(zip(a.waveformLengths, b.waveformLengths).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(zip(a.dc, b.dc).contains { abs($0 - $1) > 1_000 })
        #expect(a.rms.count == channels && a.dc.count == channels && a.values.count == samples * channels)
        #expect(a.rms.allSatisfy { $0 > 0 })
    }

    // MARK: - Training validation

    @Test func trainingRequiresAllSixLabelsAndThreeRepetitions() throws {
        var trials = trainingSet()
        let m = try model(trials)
        #expect(m.isValid)
        // Drop a label entirely.
        trials.removeAll { $0.label == .middle }
        #expect(throws: FingerBaselineModel.ModelError.missingLabels) { try model(trials) }
        // Drop one repetition of a label.
        trials = trainingSet()
        trials.removeAll { $0.label == .ring && $0.repetition == 2 }
        #expect(throws: FingerBaselineModel.ModelError.missingRepetitions) { try model(trials) }
    }

    @Test func trainingRejectsRepetitionOutsideZeroToTwo() {
        let bad = FingerCalibrationTrial(label: .index, repetition: 3, windows: (0..<12).map { _ in window(.index) })
        #expect(throws: FingerBaselineModel.ModelError.repetitionOutOfRange) { try model(trainingSet() + [bad]) }
    }

    @Test func trainingRejectsDuplicateLabelRepetitionPairs() {
        let dup = FingerCalibrationTrial(label: .index, repetition: 0, windows: (0..<12).map { _ in window(.index) })
        #expect(throws: FingerBaselineModel.ModelError.duplicateTrial) { try model(trainingSet() + [dup]) }
    }

    @Test func trainingRequiresMinimumNonOverlappingWindows() throws {
        let tooFew = FingerCalibrationTrial(label: .index, repetition: 0, windows: (0..<7).map { _ in window(.index) })
        var trials = trainingSet()
        trials.removeAll { $0.label == .index && $0.repetition == 0 }
        trials.append(tooFew)
        #expect(throws: FingerBaselineModel.ModelError.tooFewWindows) { try model(trials) }
    }

    @Test func trainingRejectsMalformedWindows() throws {
        let broken = FingerEMGFeatures(values: [1], dc: [1], rms: [1])
        let bad = FingerCalibrationTrial(label: .index, repetition: 0, windows: (0..<12).map { _ in broken })
        var trials = trainingSet()
        trials.removeAll { $0.label == .index && $0.repetition == 0 }
        trials.append(bad)
        #expect(throws: FingerBaselineModel.ModelError.invalidWindow) { try model(trials) }
    }

    // MARK: - Classification behaviour

    @Test func separatesSixSyntheticClasses() throws {
        let m = try model(trainingSet())
        #expect(m.isValid)
        for label in CalibratedFinger.allCases {
            // Fresh held-out windows (not used in training).
            for _ in 0..<10 {
                let p = m.predict(window(label))
                #expect(p.label == label, "misclassified \(label.rawValue)")
            }
        }
    }

    @Test func restOffsetsDoNotCreateFalseRecognition() throws {
        let m = try model(trainingSet())
        // Rest windows with a large DC offset still classified as rest.
        for _ in 0..<8 {
            let p = m.predict(window(.rest, offset: 10_000))
            #expect(p.label == .rest)
        }
        // A strongly-contracting finger with an offset is still that finger.
        let p = try #require(m.predict(window(.index, offset: 60_000)).label)
        #expect(p == .index)
    }

    @Test func identicalClassesYieldUnknown() throws {
        // Force index & middle to share an identical pattern so centroids collide.
        let trials = trainingSet { label in
            label == .middle ? .index : label
        }
        let m = try model(trials)
        // A middle-pattern test point is equidistant to the collided centroids.
        let p = m.predict(window(.middle))
        #expect(p.label == nil)
    }

    @Test func unseenFarAwayFeaturesRejected() throws {
        let m = try model(trainingSet())
        // A huge, unfamiliar amplitude sits outside every class envelope.
        let p = m.predict(window(.index, gain: 12_000))
        #expect(p.label == nil)
    }

    @Test func malformedInputFeaturesReturnUnknown() throws {
        let m = try model(trainingSet())
        let bad = FingerEMGFeatures(values: [1], dc: [1], rms: [1])
        var p = m.predict(bad)
        #expect(p.label == nil)
        var inf = window(.index)
        inf = FingerEMGFeatures(values: [.nan], dc: [.nan], rms: [.nan])
        p = m.predict(inf)
        #expect(p.label == nil)
    }

    // MARK: - Serialization & defensive decode

    @Test func jsonRoundTripPreservesBehaviour() throws {
        let m = try model(trainingSet())
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(FingerBaselineModel.self, from: data)
        #expect(decoded.isValid)
        #expect(decoded.restDC == m.restDC)
        #expect(decoded.restRMS == m.restRMS)
        for label in CalibratedFinger.allCases {
            let a = try #require(m.predict(window(label)).label)
            let b = try #require(decoded.predict(window(label)).label)
            #expect(a == b)
        }
    }

    @Test func malformedDecodedModelArraysDoNotCrash() throws {
        let m = try model(trainingSet())
        var dict = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        // Corrupt a model array to the wrong length and inject non-finite values.
        dict["featureMean"] = [1.0]                     // wrong length
        dict["featureScale"] = [0.0, -1.0]              // invalid scales
        dict["pooledVariance"] = [0.0, -1.0]            // non-positive variances
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(FingerBaselineModel.self, from: data)
        #expect(decoded.isValid == false)
        // predict must return unknown, not crash.
        let p = decoded.predict(window(.index))
        #expect(p.label == nil)
        #expect(p.distance.isFinite == false)
    }

    @Test func restBaselinesComeFromRestWindowsOnly() throws {
        let m = try model(trainingSet())
        // rest windows all have offset 30_000, so restDC should sit near that.
        #expect(m.restDC.count == channels)
        #expect(m.restRMS.count == channels)
        for dc in m.restDC { #expect(dc > 20_000 && dc < 40_000) }
    }
}
