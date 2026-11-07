# Personal finger baselines

Open **fingers** while your band is connected and its wrist is confirmed. This local experiment learns the muscle patterns associated with **rest, thumb, index, middle, ring, and little finger**. The eight sensor channels are not assigned one-to-one to fingers. Ring and little finger do not have built-in labels in Kinesis's existing firmware gesture decoder.

## Capture

1. Keep the band snug in a consistent position, with skin contact. Rest your forearm on a desk.
2. Select **start finger calibration**. The page acquires the existing raw EMG subscription and pauses Mac/phone controls.
3. For **rest**, relax the whole hand. For a finger cue, gently press that finger into the desk and let the others rest. A thumb cue uses the thumb alone, rather than a pinch involving another finger.
4. Select **capture** when ready. A two-second preparation cue precedes three seconds of sampling. Relax before the next repetition.
5. Complete three training rounds, followed by a fourth test round in a different order. The test round is never fitted into the classifier.

The page reports correct/total windows for each label, including misclassifications and uncertain windows. Each test label has one held-out repetition with twelve consecutive 250 ms windows; these windows are correlated, not twelve independent trials. A short successful check is not proof that all fingers work reliably across activities or band positions.

If every label reaches 75% in this check, **try live recognition** becomes available for the same connection. Predictions remain a visual preview and never trigger Mac, phone, or robot actions. Close the page or stop to release the EMG hold; controls stay paused until explicitly re-enabled.

## What is saved

A versioned profile is saved in the app's local preferences, keyed by band identity and wrist. It contains resting DC/RMS channel statistics, a fitted model, timestamp, sample rate, and held-out confusion counts. This calibration does not save raw EMG. It does not upload data or rewrite the band's built-in gesture model. Existing independently enabled recordings/streams retain their own behavior.

After a reconnect, app restart, or wearing-position change, recalibrate before using live recognition. A missed packet discards the current repetition and asks you to capture it again. Disconnects, stream restarts, invalid formats, saturation, and stalled streams stop the run. Incomplete runs are not saved.

## Method and useful libraries

The native first version uses non-overlapping 512-sample windows at the supported 2,048 Hz, removes each window's per-channel DC, and computes log-transformed RMS and mean waveform length. A regularized diagonal-distance prototype model learns six classes from three repetitions each. It rejects ambiguous and out-of-envelope windows; the distance margin is not a calibrated probability. No Python installation is required for the native page.

Useful next-stage tools:

- [LibEMG](https://libemg.github.io/libemg/): EMG feature extraction, guided training, classifiers, evaluation, and online prediction. A Kinesis stream adapter is needed; Meta Neural Band is not listed among its documented hardware streamers.
- [LibEMG guided training](https://libemg.github.io/libemg/documentation/screen_guided_training/sgt.html): examples of labeled contraction collection.
- [scikit-learn LDA](https://scikit-learn.org/stable/modules/lda_qda.html): an alternative baseline classifier for exported training data.
- [SciPy signal filtering](https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.sosfilt.html): causal filtering for a future Python signal pipeline.
- [Meta's research models](https://github.com/facebookresearch/generic-neuromotor-interface): research implementations and datasets, not a verified drop-in model for this eight-channel consumer-band stream.

Test the native core/session with `swift test --filter FingerCalibration`. Build the local app with `./scripts/build.sh --local`.
