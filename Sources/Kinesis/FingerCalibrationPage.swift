import SwiftUI
import KinesisCore

struct FingerCalibrationPage: View {
    @ObservedObject var model: BandModel
    @ObservedObject var calibration: FingerCalibrationController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("learn your fingers.").font(KinesisType.title).tracking(-1.2)
            Text("Build a personal muscle baseline for rest, thumb, index, middle, ring, and little finger. Keep the band snug in one position and support your forearm on a desk.")
                .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = calibration.problem { ErrorNote(text: problem) }
            if calibration.active { session } else { introduction }
            if calibration.active {
                channelLevels
                Button("stop calibration") { calibration.stop() }.buttonStyle(KinesisButtonStyle())
            }
            if let profile = calibration.profile, !calibration.active { results(profile) }
            Text("This learns patterns from your eight muscle-signal channels. A channel does not correspond to one finger. Results apply to this wearing position; recalibrate after moving the band. This page saves a local summary and model, and does not change the band’s built-in gestures.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { calibration.loadProfile() }
        .onDisappear { calibration.stop() }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            OpenRow(title: "personal calibration", detail: "24 short repetitions · about 3–5 minutes") { EmptyView() }
            Text("Three rounds teach the patterns. A fourth round tests new repetitions, including rest. Each capture gives you 2 seconds to prepare, then records 3 seconds. Relax between repetitions and press “capture” when ready.")
                .font(KinesisType.caption).fixedSize(horizontal: false, vertical: true)
            Text("For each finger, gently press that finger into the desk while the others rest. Use similar pressure each time. Thumb presses should use the thumb alone, rather than pinching another finger.")
                .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(calibration.profile == nil ? "start finger calibration" : "calibrate again") { calibration.start() }
                .buttonStyle(KinesisButtonStyle(prominent: true)).disabled(!calibration.canStart)
            if !model.live { Text("Connect the band first.").font(KinesisType.caption) }
            else if !model.handConfirmed { Text("Wait for the band to confirm your wrist.").font(KinesisType.caption) }
            else if !calibration.canStart { Text("Finish the other band operation or recording first.").font(KinesisType.caption) }
        }
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 16) {
            if calibration.phase == .waiting {
                ProgressView("checking live muscle signals…")
            } else if calibration.phase == .preview {
                SectionLabel(text: "live recognition · experimental")
                Text(calibration.prediction?.rawValue ?? "uncertain").font(.system(size: 40, weight: .medium))
                Text("Try the same gentle finger presses. This preview does not send actions.")
                    .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
            } else {
                HStack {
                    SectionLabel(text: calibration.repetition == 3 ? "test round · new examples" : "training round \(calibration.repetition + 1) of 3")
                    Spacer()
                    Text("\(calibration.trialIndex + 1) / 24").font(KinesisType.micro)
                }
                Text(calibration.label == .rest ? "relaxed hand" : "\(calibration.label.rawValue) finger")
                    .font(.system(size: 36, weight: .medium)).accessibilityAddTraits(.isHeader)
                Text(calibration.prompt).font(KinesisType.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if calibration.phase == .ready {
                    Button("capture \(calibration.label.rawValue)") { calibration.capture() }
                        .buttonStyle(KinesisButtonStyle(prominent: true))
                } else if calibration.phase == .preparing {
                    Text("get ready… \(calibration.countdown)").font(.system(size: 26, weight: .medium))
                } else {
                    Text(calibration.label == .rest ? "keep relaxed" : "hold the gentle press").font(KinesisType.caption)
                    ProgressView(value: calibration.progress)
                        .accessibilityLabel("Capture progress")
                }
            }
            Text("Mac and phone controls are paused during calibration.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
        }.padding(20).background(KinesisStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private var channelLevels: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "live signal · 8 channels")
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(0..<8) { index in
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(KinesisStyle.accent)
                            .frame(height: max(3, min(55, log1p(calibration.liveRMS[index]) * 7)))
                        Text("\(index + 1)").font(KinesisType.micro)
                    }.frame(maxWidth: .infinity)
                    .accessibilityLabel("Channel \(index + 1), RMS \(Int(calibration.liveRMS[index])) ADC counts")
                }
            }.frame(height: 78, alignment: .bottom)
        }
    }

    private func results(_ profile: FingerCalibrationProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            OpenRow(title: "saved baseline", detail: "\(profile.hand) wrist · \(profile.created.formatted(date: .abbreviated, time: .shortened))") { EmptyView() }
            Text("New-repetition check: \(profile.correct) / \(profile.total) windows matched")
                .font(KinesisType.caption)
            Text(profile.passed ? "All six labels reached at least 75% in this short check. Try the live preview next."
                 : "Some labels overlap or are uncertain. Try a steadier band position and clearer, consistent finger presses, then recalibrate.")
                .font(KinesisType.caption).foregroundStyle(profile.passed ? KinesisStyle.secondary : KinesisStyle.warning)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(profile.validation) { row in
                HStack(alignment: .top) {
                    Text(row.finger.rawValue).frame(width: 60, alignment: .leading)
                    Text("\(row.correct) / \(row.total)").monospacedDigit().frame(width: 55, alignment: .trailing)
                    Text(row.counts.filter { $0.key != row.finger.rawValue && $0.value > 0 }
                        .sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                        .foregroundStyle(KinesisStyle.secondary)
                    Spacer(minLength: 0)
                }.font(KinesisType.micro)
            }
            HStack(spacing: 16) {
                Text("Rest RMS, channels 1–8: \(profile.model.restRMS.map { String(format: "%.1f", $0) }.joined(separator: " · "))")
                    .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if calibration.validatedThisConnection && profile.passed {
                Button("try live recognition") { calibration.startPreview() }
                    .buttonStyle(KinesisButtonStyle(prominent: true)).disabled(!calibration.canStart)
            } else if !calibration.validatedThisConnection {
                Text("Recalibrate for this connection before using live recognition.")
                    .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
            }
            Text("These are 250 ms windows from one held-out repetition per label, not independent trials or a guarantee of finger recognition. Raw EMG is not saved by this calibration.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
