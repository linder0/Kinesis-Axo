import Foundation

/// The discrete finger gestures a baseline classifier can distinguish.
///
/// `rest` is always the resting (no finger extended) state. This is a
/// heuristic personal baseline label, not a guarantee of real-user accuracy.
public enum CalibratedFinger: String, CaseIterable, Codable, Sendable {
    case rest, thumb, index, middle, ring, little
}

/// A fixed-size window of raw EMG samples together with simple derived stats.
///
/// Features are intentionally invariant to an ADC DC offset (see
/// ``extract(_:)``), so a steady rest offset is never treated as finger
/// evidence.
public struct FingerEMGFeatures: Codable, Sendable {
    /// Raw interleaved samples over this window, sample-major
    /// (`index = sample * channelCount + channel`).
    public let values: [Double]
    /// Per-channel arithmetic mean (the DC offset), for monitoring only.
    public let dc: [Double]
    /// Per-channel zero-mean root-mean-square amplitude.
    public let rms: [Double]

    /// Interleaved sample count is `sampleCount * channelCount`.
    public static let sampleCount = 512
    public static let channelCount = 8

    enum ExtractionError: Error, Equatable {
        case wrongShape
        case nonfinite
        case outOfUInt16Range
        case flatSignal
    }

    /// Builds features from an interleaved sample-major buffer.
    ///
    /// Rejects wrong shapes, non-finite or out-of-`UInt16`-range samples, and
    /// all-channel-flat (zero amplitude) signals.
    public static func extract(_ interleavedSamples: [Double]) throws -> FingerEMGFeatures {
        let ch = channelCount
        let spc = sampleCount
        guard interleavedSamples.count == spc * ch else { throw ExtractionError.wrongShape }

        var rmsOut = [Double](repeating: 0, count: ch)
        var dcOut = [Double](repeating: 0, count: ch)
        var anyActive = false

        for c in 0..<ch {
            var runningMean = 0.0
            var runningM2 = 0.0
            var n = 0
            for i in 0..<spc {
                let v = interleavedSamples[i * ch + c]
                guard v.isFinite else { throw ExtractionError.nonfinite }
                guard v >= 0 && v <= Double(UInt16.max) else { throw ExtractionError.outOfUInt16Range }
                n += 1
                let delta = v - runningMean
                runningMean += delta / Double(n)
                runningM2 += delta * (v - runningMean)
            }
            dcOut[c] = runningMean
            let variance = runningM2 / Double(spc)
            let r = variance > 0 ? sqrt(variance) : 0
            rmsOut[c] = r
            if r > 0 { anyActive = true }
        }

        guard anyActive else { throw ExtractionError.flatSignal }
        return FingerEMGFeatures(values: interleavedSamples, dc: dcOut, rms: rmsOut)
    }

    /// Per-channel mean waveform length (average absolute adjacent-sample
    /// difference). Invariant to DC offset.
    var waveformLengths: [Double] {
        let ch = FingerEMGFeatures.channelCount
        let spc = FingerEMGFeatures.sampleCount
        var out = [Double](repeating: 0, count: ch)
        for c in 0..<ch {
            var sum = 0.0
            for i in 0..<(spc - 1) {
                sum += abs(values[(i + 1) * ch + c] - values[i * ch + c])
            }
            out[c] = sum / Double(spc - 1)
        }
        return out
    }
}

/// A single calibration trial: one repetition of one gesture across several
/// non-overlapping feature windows.
public struct FingerCalibrationTrial: Codable, Sendable {
    public let label: CalibratedFinger
    public let repetition: Int
    public let windows: [FingerEMGFeatures]

    public init(label: CalibratedFinger, repetition: Int, windows: [FingerEMGFeatures]) {
        self.label = label
        self.repetition = repetition
        self.windows = windows
    }
}

/// Result of a single baseline prediction. `margin` is a heuristic relative
/// separation measure and is never a probability.
public struct FingerPrediction: Sendable {
    /// The winning label, or `nil` when the prediction is ambiguous or the
    /// feature falls outside every class training envelope.
    public let label: CalibratedFinger?
    public let margin: Double
    public let distance: Double
}

/// A standardized nearest-centroid baseline model trained from six calibrated
/// finger labels.
///
/// All scale and mean statistics are fit only on training data. Repeated calls
/// against the same features are deterministic.
public struct FingerBaselineModel: Codable, Sendable {
    /// Number of log1p classifier features: per-channel RMS and waveform length.
    public static let featureLength = 2 * FingerEMGFeatures.channelCount
    private static let minWindowsPerTrial = 8
    private static let maxWindowsPerTrial = 128
    private static let ambiguityMargin = 0.12
    private static let varianceRegularization = 0.001
    /// Slightly widens each per-class envelope so held-out samples from the same
    /// distribution are not spuriously rejected.
    private static let envelopeFactor = 1.2
    /// Absolute floor for a class envelope so numerically-identical training
    /// windows (zero noise) do not collapse the envelope to zero and reject
    /// equivalent held-out points merely due to floating-point jitter.
    private static let envelopeFloor = 1e-6

    /// Per-channel DC baseline averaged only across `rest` training windows.
    public let restDC: [Double]
    /// Per-channel RMS baseline averaged only across `rest` training windows.
    public let restRMS: [Double]

    private let featureMean: [Double]
    private let featureScale: [Double]
    private let pooledVariance: [Double]
    private let centroids: [[Double]]
    private let envelopes: [Double]

    enum ModelError: Error {
        case tooFewWindows
        case invalidWindow
        case repetitionOutOfRange
        case duplicateTrial
        case missingLabels
        case missingRepetitions
    }

    /// Trains the baseline model.
    ///
    /// Requires all six labels, three distinct repetitions (`0`, `1`, `2`) per
    /// label, at least ``FingerBaselineModel/minWindowsPerTrial`` non-overlapping
    /// feature windows per trial, and no duplicate label/repetition pairs.
    /// Repetitions outside `0...2` are rejected so a held-out `3` cannot leak.
    public init(training: [FingerCalibrationTrial]) throws {
        let labels = CalibratedFinger.allCases
        let ch = FingerEMGFeatures.channelCount

        var repsByLabel: [CalibratedFinger: Set<Int>] = [:]
        var seenPairs: Set<String> = []

        for trial in training {
            guard (0...2).contains(trial.repetition) else { throw ModelError.repetitionOutOfRange }
            let key = "\(trial.label.rawValue):\(trial.repetition)"
            guard seenPairs.insert(key).inserted else { throw ModelError.duplicateTrial }
            repsByLabel[trial.label, default: []].insert(trial.repetition)
            guard trial.windows.count >= Self.minWindowsPerTrial else { throw ModelError.tooFewWindows }
            guard trial.windows.count <= Self.maxWindowsPerTrial else { throw ModelError.invalidWindow }
            for window in trial.windows {
                guard Self.validWindow(window) else { throw ModelError.invalidWindow }
            }
        }

        for label in labels {
            guard let reps = repsByLabel[label] else { throw ModelError.missingLabels }
            guard reps.isSuperset(of: [0, 1, 2]) else { throw ModelError.missingRepetitions }
        }

        var perClass: [[[Double]]] = Array(repeating: [], count: labels.count)
        var restDCSum = [Double](repeating: 0, count: ch)
        var restRMSSum = [Double](repeating: 0, count: ch)
        var restCount = 0

        for trial in training {
            let idx = labels.firstIndex(of: trial.label)!
            let windows = Array(trial.windows.prefix(Self.maxWindowsPerTrial))
            for window in windows {
                guard let vector = Self.buildFeatureVector(window) else { throw ModelError.invalidWindow }
                perClass[idx].append(vector)
                if trial.label == .rest {
                    for c in 0..<ch {
                        restDCSum[c] += window.dc[c]
                        restRMSSum[c] += window.rms[c]
                    }
                    restCount += 1
                }
            }
        }

        let all = perClass.flatMap { $0 }
        let dim = Self.featureLength

        var mean = [Double](repeating: 0, count: dim)
        for v in all { for i in 0..<dim { mean[i] += v[i] } }
        if !all.isEmpty { for i in 0..<dim { mean[i] /= Double(all.count) } }

        var scale = [Double](repeating: 0, count: dim)
        for v in all { for i in 0..<dim { let d = v[i] - mean[i]; scale[i] += d * d } }
        if !all.isEmpty {
            for i in 0..<dim {
                let s = sqrt(scale[i] / Double(all.count))
                scale[i] = s == 0 ? 1.0 : s
            }
        }

        // Standardize training vectors and compute per-class centroids.
        let stdVectors = perClass.map { cls in cls.map { v in Self.standardize(v, mean: mean, scale: scale) } }
        var centroids = [[Double]](repeating: [Double](repeating: 0, count: dim), count: labels.count)
        for cls in 0..<labels.count {
            let list = stdVectors[cls]
            guard !list.isEmpty else { continue }
            for v in list { for i in 0..<dim { centroids[cls][i] += v[i] } }
            for i in 0..<dim { centroids[cls][i] /= Double(list.count) }
        }

        // Pooled, regularized within-class variance (diagonal).
        var pooled = [Double](repeating: 0, count: dim)
        var classCount = 0
        for cls in 0..<labels.count {
            let list = stdVectors[cls]
            guard !list.isEmpty else { continue }
            classCount += 1
            let c = centroids[cls]
            for i in 0..<dim {
                var s = 0.0
                for v in list { let d = v[i] - c[i]; s += d * d }
                pooled[i] += s / Double(list.count)
            }
        }
        if classCount > 0 {
            for i in 0..<dim { pooled[i] = pooled[i] / Double(classCount) + Self.varianceRegularization }
        }
        // Regularized pooled variance must stay strictly positive.
        for i in 0..<dim { if pooled[i] <= 0 { pooled[i] = Self.varianceRegularization } }

        // Per-class training-distance envelopes.
        var envelopes = [Double](repeating: 0, count: labels.count)
        for cls in 0..<labels.count {
            let list = stdVectors[cls]
            guard !list.isEmpty else { continue }
            var worst = 0.0
            for v in list {
                let d = Self.weightedDistance(v, centroids[cls], pooled)
                if d > worst { worst = d }
            }
            envelopes[cls] = max(worst * Self.envelopeFactor, Self.envelopeFloor)
        }

        restDC = restCount > 0 ? restDCSum.map { $0 / Double(restCount) } : [Double](repeating: 0, count: ch)
        restRMS = restCount > 0 ? restRMSSum.map { $0 / Double(restCount) } : [Double](repeating: 0, count: ch)
        featureMean = mean
        featureScale = scale
        pooledVariance = pooled
        self.centroids = centroids
        self.envelopes = envelopes
    }

    /// True when every stored model array has the correct, finite shape.
    public var isValid: Bool {
        let dim = Self.featureLength
        let ch = FingerEMGFeatures.channelCount
        guard restDC.count == ch, restRMS.count == ch,
              featureMean.count == dim, featureScale.count == dim,
              pooledVariance.count == dim,
              envelopes.count == CalibratedFinger.allCases.count,
              centroids.count == CalibratedFinger.allCases.count else { return false }
        guard centroids.allSatisfy({ $0.count == dim }) else { return false }
        let arrays = (restDC + restRMS + featureMean + featureScale + pooledVariance + envelopes).flatMap { [$0] }
        let flatCentroids = centroids.flatMap { $0 }
        guard arrays.allSatisfy(\.isFinite), flatCentroids.allSatisfy(\.isFinite) else { return false }
        return featureScale.allSatisfy { $0 > 0 } && pooledVariance.allSatisfy { $0 > 0 }
            && envelopes.allSatisfy { $0 > 0 }
            && restDC.allSatisfy { (0...Double(UInt16.max)).contains($0) }
            && restRMS.allSatisfy { (0...Double(UInt16.max)).contains($0) }
    }

    /// Produces a heuristic prediction. Never crashes; returns `nil` label when
    /// the input features are malformed or non-finite, the model is invalid, the
    /// feature falls outside every class envelope, or the relative margin is
    /// below the ambiguity threshold.
    public func predict(_ features: FingerEMGFeatures) -> FingerPrediction {
        guard isValid, let vector = Self.buildFeatureVector(features) else {
            return FingerPrediction(label: nil, margin: 0, distance: .infinity)
        }
        let z = Self.standardize(vector, mean: featureMean, scale: featureScale)
        var bestIndex = 0
        var bestDist = Double.greatestFiniteMagnitude
        var secondDist = Double.greatestFiniteMagnitude
        for (i, c) in centroids.enumerated() {
            let d = Self.weightedDistance(z, c, pooledVariance)
            if d < bestDist {
                secondDist = bestDist
                bestDist = d
                bestIndex = i
            } else if d < secondDist {
                secondDist = d
            }
        }
        // Reject features that fall outside the winning class's training envelope.
        guard bestDist <= envelopes[bestIndex] else {
            return FingerPrediction(label: nil, margin: 0, distance: bestDist)
        }
        // An exact, unique centroid match is strong evidence. A zero-distance tie
        // remains unknown. Normalize by the runner-up so the margin is in 0...1.
        let margin = (secondDist - bestDist) / max(secondDist, 1e-12)
        guard margin >= Self.ambiguityMargin else {
            return FingerPrediction(label: nil, margin: margin, distance: bestDist)
        }
        return FingerPrediction(label: CalibratedFinger.allCases[bestIndex], margin: margin, distance: bestDist)
    }

    // MARK: - helpers

    private static func validWindow(_ w: FingerEMGFeatures) -> Bool {
        let ch = FingerEMGFeatures.channelCount
        let spc = FingerEMGFeatures.sampleCount
        guard w.dc.count == ch, w.rms.count == ch, w.values.count == spc * ch else { return false }
        guard w.dc.allSatisfy({ $0.isFinite && (0...Double(UInt16.max)).contains($0) }),
              w.rms.allSatisfy({ $0.isFinite && (0...Double(UInt16.max)).contains($0) }),
              w.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= Double(UInt16.max) }) else { return false }
        return true
    }

    private static func buildFeatureVector(_ w: FingerEMGFeatures) -> [Double]? {
        guard validWindow(w) else { return nil }
        let ch = FingerEMGFeatures.channelCount
        let lengths = w.waveformLengths
        var v = [Double]()
        v.reserveCapacity(featureLength)
        for c in 0..<ch { v.append(log1p(w.rms[c])) }
        for c in 0..<ch { v.append(log1p(lengths[c])) }
        return v
    }

    private static func standardize(_ v: [Double], mean: [Double], scale: [Double]) -> [Double] {
        var out = v
        for i in 0..<v.count { out[i] = (v[i] - mean[i]) / scale[i] }
        return out
    }

    private static func weightedDistance(_ a: [Double], _ b: [Double], _ variance: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sum += d * d / variance[i]
        }
        return sqrt(sum)
    }
}
