import Foundation
import CoreGraphics
import Testing
@testable import Zonas

@Suite("Gaze POC: independently tested calibration, abstention and window geometry")
struct GazeTests {
    private func features(_ p: CGPoint, noise: Double = 0) -> Gaze.Features {
        Gaze.Features(values: [0.40 * (p.x - 0.5) + noise, 0.25 * (0.5 - p.y) + noise,
                               0.38 * (p.x - 0.5) - noise, 0.24 * (0.5 - p.y) - noise,
                               noise, -noise, noise, 0.50, 0.60, 0.30])
    }
    private func group(_ point: CGPoint, samples: Int = 30) -> Gaze.Group {
        Gaze.Group(target: point, samples: (0..<samples).map { features(point, noise: Double($0 % 7 - 3) * 0.001) })
    }
    private var training: [Gaze.Group] { GazeExperimentController.trainingTargets.map { group($0) } }
    private var test: [Gaze.Group] { GazeExperimentController.testTargets.map { group($0) } }

    @Test("Calibration collection excludes transitions, stale or duplicate frames")
    func collectionTiming() {
        var c = Gaze.Collector(began: 10)
        let f = features(CGPoint(x: 0.5, y: 0.5))
        c.add(f, at: 9); c.add(f, at: 10.5); c.add(nil, at: 10.95)
        #expect(c.samples.isEmpty)
        for i in 0..<18 { c.add(f, at: 11 + Double(i) * 0.07) }
        #expect(c.samples.count == 18)
        #expect(!c.ready(at: 12.5))
        #expect(c.ready(at: 12.7))
        c.add(f, at: 11); c.add(f, at: .nan); c.add(f, at: 18)
        #expect(c.samples.count == 18)
        #expect(c.timedOut(at: 17.1))
        #expect(!c.ready(at: 17.1))
        let next = Gaze.Collector(began: 13)
        #expect(next.samples.isEmpty)
    }

    @Test("A partial calibration point cannot proceed and collection is bounded")
    func collectionLimits() {
        var c = Gaze.Collector(began: 0)
        let f = features(CGPoint(x: 0.5, y: 0.5))
        for i in 0..<17 { c.add(f, at: 1 + Double(i) * 0.07) }
        #expect(!c.ready(at: 3))
        for i in 0..<200 { c.add(f, at: 3 + Double(i) * 0.01) }
        #expect(c.samples.count == 90)
        #expect(c.ready(at: 6))
        c.add(Gaze.Features(values: [.nan]), at: 6)
        #expect(c.samples.count == 90)
    }

    @Test("Learn eye motion and succeed on six unseen spatial targets")
    func heldOutSpatialValidation() throws {
        let model = try #require(Gaze.fit(training))
        let result = try #require(Gaze.validate(model, groups: test, trainingTargets: training.map(\.target)))
        #expect(result.passed)
        #expect(result.correctRegions == 6)
        #expect(result.medianError < 0.025)
        #expect(result.coverage == 1)
    }

    @Test("A mirrored or shifted gaze fails even if calibration fitted")
    func incorrectTest() throws {
        let model = try #require(Gaze.fit(training))
        let wrong = test.map { g in Gaze.Group(target: g.target, samples: g.samples.map { _ in
            features(CGPoint(x: 1 - g.target.x, y: 1 - g.target.y))
        }) }
        let result = try #require(Gaze.validate(model, groups: wrong, trainingTargets: training.map(\.target)))
        #expect(!result.passed)
        #expect(result.p90Error > 0.18)
    }

    @Test("Frames from trained dots are not independent validation")
    func refusesLeakage() throws {
        let model = try #require(Gaze.fit(training))
        #expect(Gaze.validate(model, groups: training, trainingTargets: training.map(\.target)) == nil)
        #expect(Gaze.validate(model, groups: Array(repeating: test[0], count: 6), trainingTargets: training.map(\.target)) == nil)
    }

    @Test("Bad samples, missing targets, duplicate dots and small coverage cannot fit")
    func calibrationGuards() {
        #expect(Gaze.fit(Array(training.prefix(8))) == nil)
        #expect(Gaze.fit(training.map { group($0.target, samples: 11) }) == nil)
        #expect(Gaze.fit(Array(repeating: training[0], count: 9)) == nil)
        #expect(Gaze.fit(training.map { group(CGPoint(x: 0.4 + $0.target.x * 0.1, y: 0.4 + $0.target.y * 0.1)) }) == nil)
        var bad = training
        bad[0] = Gaze.Group(target: bad[0].target, samples: Array(repeating: Gaze.Features(values: [.nan]), count: 30))
        #expect(Gaze.fit(bad) == nil)
    }

    @Test("Head motion alone must not masquerade as pupil gaze")
    func noHeadOnlyModel() {
        let groups = training.map { g in Gaze.Group(target: g.target, samples: (0..<30).map { _ in
            Gaze.Features(values: [0, 0, 0, 0, g.target.x, g.target.y, 0, 0.5, 0.6, 0.3])
        }) }
        #expect(Gaze.fit(groups) == nil)
    }

    @Test("A seating or camera position change abstains instead of extrapolating")
    func movedCamera() throws {
        let model = try #require(Gaze.fit(training))
        var shifted = features(CGPoint(x: 0.5, y: 0.5)).values
        shifted[7] += 0.2
        #expect(model.predict(Gaze.Features(values: shifted)) == nil)
        shifted[7] = 0.5; shifted[9] = 0.5
        #expect(model.predict(Gaze.Features(values: shifted)) == nil)
        #expect(model.predict(Gaze.Features(values: Array(repeating: .infinity, count: 10))) == nil)
    }

    @Test("Frame count at one dot cannot dominate the model")
    func droppedFrames() throws {
        var uneven = training
        uneven[0] = group(uneven[0].target, samples: 300)
        let model = try #require(Gaze.fit(uneven))
        let result = try #require(Gaze.validate(model, groups: test, trainingTargets: uneven.map(\.target)))
        #expect(result.passed)
    }

    @Test("Seeded sensor noise and independent head motion cannot overfit unseen dots", arguments: 0..<20)
    func noiseStress(seed: Int) throws {
        var state = UInt64(seed + 1)
        func noise(_ amplitude: Double) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 32) / Double(UInt32.max) - 0.5) * amplitude * 2
        }
        func noisyGroup(_ p: CGPoint) -> Gaze.Group {
            Gaze.Group(target: p, samples: (0..<30).map { _ in
                var v = features(p).values
                for i in 0..<4 { v[i] += noise(0.008) }
                for i in 4..<7 { v[i] = noise(0.04) }
                return Gaze.Features(values: v)
            })
        }
        let train = GazeExperimentController.trainingTargets.map(noisyGroup)
        let model = try #require(Gaze.fit(train))
        let heldOut = GazeExperimentController.testTargets.map(noisyGroup)
        let result = try #require(Gaze.validate(model, groups: heldOut, trainingTargets: train.map(\.target)))
        #expect(result.passed)
        #expect(result.medianError < 0.04)
    }

    @Test("Out-of-domain test frames count as failures, not discarded successes")
    func validationCoverage() throws {
        let model = try #require(Gaze.fit(training))
        let unavailable = test.map { g in Gaze.Group(target: g.target, samples: g.samples.map { f in
            var v = f.values; v[7] = 0.9; return Gaze.Features(values: v)
        }) }
        let result = try #require(Gaze.validate(model, groups: unavailable, trainingTargets: training.map(\.target)))
        #expect(!result.passed)
        #expect(result.coverage == 0)
        #expect(result.medianError == 1)
    }

    @Test("Eye coordinates tolerate head roll and camera resolution")
    func normalizedEye() throws {
        let contour = [CGPoint(x: 0.2, y: 0.4), CGPoint(x: 0.35, y: 0.48), CGPoint(x: 0.65, y: 0.48),
                       CGPoint(x: 0.8, y: 0.4), CGPoint(x: 0.65, y: 0.32), CGPoint(x: 0.35, y: 0.32)]
        let pupil = CGPoint(x: 0.56, y: 0.42)
        let original = try #require(Gaze.eye(contour: contour, pupil: pupil))
        func transform(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x * cos(0.3) - p.y * sin(0.3)) * 2 + 1,
                    y: (p.x * sin(0.3) + p.y * cos(0.3)) * 2 - 1)
        }
        let rolled = try #require(Gaze.eye(contour: contour.map(transform), pupil: transform(pupil)))
        #expect(Gaze.distance(original, rolled) < 0.000001)
        #expect(abs(original.x - 0.1) < 0.000001)
    }

    @Test("Closed eyes, missing contours and implausible pupils abstain")
    func blinks() {
        let closed = (0..<6).map { CGPoint(x: 0.2 + Double($0) * 0.1, y: 0.4) }
        #expect(Gaze.eye(contour: closed, pupil: CGPoint(x: 0.5, y: 0.4)) == nil)
        #expect(Gaze.eye(contour: [], pupil: .zero) == nil)
        #expect(Gaze.eye(contour: closed, pupil: CGPoint(x: .nan, y: 0.4)) == nil)
    }

    @Test("A fixation needs time; fresh and old frames cannot be mixed")
    func fixationLifecycle() {
        var f = Gaze.Fixation()
        for i in 0..<7 { f.add(CGPoint(x: 0.5, y: 0.5), at: 10 + Double(i) * 0.06) }
        #expect(f.stable(at: 10.37) != nil)
        #expect(f.stable(at: 10.7) == nil)
        #expect(f.stable(at: 9) == nil)
        f.add(nil, at: 10.38)
        #expect(f.stable(at: 10.4) == nil)
        f.add(CGPoint(x: 0.5, y: 0.5), at: 11)
        #expect(f.stable(at: 11.1) == nil)
    }

    @Test("A saccade, a camera gap and reversed timestamps reset dwell")
    func changingFixation() {
        var f = Gaze.Fixation()
        for i in 0..<7 { f.add(CGPoint(x: 0.2, y: 0.5), at: Double(i) * 0.06) }
        f.add(CGPoint(x: 0.8, y: 0.5), at: 0.42)
        #expect(f.stable(at: 0.43) == nil)
        for i in 8..<15 { f.add(CGPoint(x: 0.8, y: 0.5), at: Double(i) * 0.06) }
        #expect(f.stable(at: 0.85) != nil)
        f.add(CGPoint(x: 0.8, y: 0.5), at: 1.2)
        #expect(f.stable(at: 1.21) == nil)
        f.add(CGPoint(x: 0.8, y: 0.5), at: 0.5)
        #expect(f.stable(at: 1.21) == nil)
    }

    @Test("Jitter and invalid coordinates cannot suggest a window")
    func jitter() {
        var f = Gaze.Fixation()
        for i in 0..<10 { f.add(CGPoint(x: 0.5 + Double(i % 2) * 0.06, y: 0.5), at: Double(i) * 0.06) }
        #expect(f.stable(at: 0.55) == nil)
        f.add(CGPoint(x: .infinity, y: 0.5), at: 0.6)
        #expect(f.stable(at: 0.61) == nil)
    }

    @Test("Live fixation diagnostics distinguish collection, stability, expiry and missing observations")
    func fixationDiagnostics() throws {
        var f = Gaze.Fixation()
        #expect(f.decision(at: 0).state == .missing)
        #expect(f.decision(at: 0).progress == 0)
        for i in 0..<4 { f.add(CGPoint(x: 0.25, y: 0.75), at: Double(i) * 0.11) }
        let incomplete = f.decision(at: 0.34)
        #expect(incomplete.state == .collecting)
        #expect(abs(incomplete.progress - 0.8) < 0.000001)
        #expect(incomplete.stablePoint == nil)
        #expect(f.stable(at: 0.34) == nil)
        f.add(CGPoint(x: 0.25, y: 0.75), at: 0.44)
        let complete = f.decision(at: 0.45)
        #expect(complete.state == .stable)
        #expect(complete.progress == 1)
        #expect(try #require(complete.stablePoint) == CGPoint(x: 0.25, y: 0.75))
        #expect(f.stable(at: 0.45) == complete.stablePoint)
        #expect(f.decision(at: 0.8).state == .stale)
        #expect(f.decision(at: 0.8).stablePoint == nil)
        #expect(f.decision(at: 0.43).state == .stale)
        #expect(f.decision(at: .nan).state == .stale)
        f.add(nil, at: 0.81)
        #expect(f.decision(at: 0.82).state == .missing)
    }

    @Test("Dwell progress uses observed time rather than an idle timer and jitter still abstains")
    func fixationProgressAndJitter() {
        var brief = Gaze.Fixation()
        for i in 0..<7 { brief.add(CGPoint(x: 0.5, y: 0.5), at: Double(i) * 0.01) }
        let before = brief.decision(at: 0.07)
        let later = brief.decision(at: 0.2)
        #expect(before.state == .collecting)
        #expect(abs(before.progress - 0.2) < 0.000001)
        #expect(later.progress == before.progress)
        #expect(later.stablePoint == nil)
        var jitter = Gaze.Fixation()
        for i in 0..<10 { jitter.add(CGPoint(x: 0.5 + Double(i % 2) * 0.06, y: 0.5), at: Double(i) * 0.06) }
        let moving = jitter.decision(at: 0.55)
        #expect(moving.state == .unstable)
        #expect(moving.progress == 1)
        #expect(moving.stablePoint == nil)
        #expect(jitter.stable(at: 0.55) == nil)
        jitter.add(CGPoint(x: 0.8, y: 0.5), at: 0.6)
        #expect(jitter.decision(at: 0.61).state == .collecting)
        #expect(jitter.decision(at: 0.61).progress == 0)
    }

    private let screen = CGRect(x: -5120, y: -800, width: 5120, height: 1440)
    private var left: Gaze.Window { Gaze.Window(id: 1, bounds: CGRect(x: -5120, y: -800, width: 2560, height: 1440)) }
    private var right: Gaze.Window { Gaze.Window(id: 2, bounds: CGRect(x: -2560, y: -800, width: 2560, height: 1440)) }
    private func candidate(_ p: CGPoint, radius: CGSize = CGSize(width: 0.03, height: 0.03),
                           windows: [Gaze.Window]? = nil, eligible: Set<UInt32> = [1, 2]) -> UInt32? {
        Gaze.candidate(point: p, radius: radius, screen: screen, windows: windows ?? [left, right], eligible: eligible)
    }

    @Test("CG global negative origins on an ultrawide preserve left/right and Y")
    func multiMonitor() {
        #expect(candidate(CGPoint(x: 0.25, y: 0.5)) == 1)
        #expect(candidate(CGPoint(x: 0.75, y: 0.5)) == 2)
        let top = Gaze.Window(id: 3, bounds: CGRect(x: -5120, y: -800, width: 5120, height: 720))
        #expect(candidate(CGPoint(x: 0.25, y: 0.25), windows: [top, left], eligible: [1, 3]) == 3)
        #expect(candidate(CGPoint(x: 0.25, y: 0.75), windows: [top, left], eligible: [1, 3]) == 1)
    }

    @Test("Borders, desktop space, off-screen estimates and minimized windows abstain")
    func boundaries() {
        #expect(candidate(CGPoint(x: 0.5, y: 0.5)) == nil)
        #expect(candidate(CGPoint(x: 0.25, y: 0.5), windows: []) == nil)
        #expect(candidate(CGPoint(x: 0.01, y: 0.5)) == nil)
        #expect(candidate(CGPoint(x: 0.25, y: 0.5), eligible: [2]) == nil)
        #expect(candidate(CGPoint(x: .nan, y: 0.5)) == nil)
        #expect(candidate(CGPoint(x: 0.25, y: 0.5), radius: CGSize(width: -1, height: 0)) == nil)
    }

    @Test("Overlapping windows use visible front-to-back order, not nearest centre")
    func occlusion() {
        let covering = Gaze.Window(id: 4, bounds: left.bounds)
        #expect(candidate(CGPoint(x: 0.25, y: 0.5), windows: [covering, left], eligible: [1, 4]) == 4)
        #expect(candidate(CGPoint(x: 0.25, y: 0.5), windows: [left, covering], eligible: [1, 4]) == 1)
        #expect(candidate(CGPoint(x: 0.25, y: 0.5), windows: [covering, left], eligible: [1]) == nil)
    }

    @Test("An unlisted small dialog between uncertainty probes still blocks")
    func smallBlocker() {
        let dialog = Gaze.Window(id: 9, bounds: CGRect(x: -3810, y: -74, width: 12, height: 12))
        #expect(candidate(CGPoint(x: 0.25, y: 0.5), windows: [dialog, left], eligible: [1]) == nil)
    }

    @Test("Live window decisions explain selected, desktop, border and outside-display estimates")
    func candidateDiagnostics() {
        func decision(_ p: CGPoint, windows: [Gaze.Window]? = nil) -> Gaze.CandidateDecision {
            Gaze.candidateDecision(point: p, radius: CGSize(width: 0.03, height: 0.03),
                                   screen: screen, windows: windows ?? [left, right], eligible: [1, 2])
        }
        let selected = decision(CGPoint(x: 0.25, y: 0.5))
        #expect(selected.reason == .accepted)
        #expect(selected.candidateID == 1)
        #expect(candidate(CGPoint(x: 0.25, y: 0.5)) == selected.candidateID)
        let border = decision(CGPoint(x: 0.5, y: 0.5))
        #expect(border.reason == .nearWindowEdge)
        #expect(border.candidateID == nil)
        #expect(decision(CGPoint(x: 0.515, y: 0.5), windows: [right]).reason == .nearWindowEdge)
        #expect(decision(CGPoint(x: 0.25, y: 0.5), windows: []).reason == .desktop)
        #expect(decision(CGPoint(x: 0.01, y: 0.5)).reason == .outsideDisplay)
        #expect(decision(CGPoint(x: 1.1, y: 0.5)).reason == .outsideDisplay)
        #expect(decision(CGPoint(x: .nan, y: 0.5)).reason == .invalidInput)
        #expect(Gaze.candidateDecision(point: CGPoint(x: 0.25, y: 0.5),
                                      radius: CGSize(width: -1, height: 0), screen: screen,
                                      windows: [left], eligible: [1]).reason == .invalidInput)
    }

    @Test("Diagnostic explanations respect unlisted blockers between probes and visible z-order")
    func blockerDiagnostics() {
        let p = CGPoint(x: 0.25, y: 0.5)
        let radius = CGSize(width: 0.03, height: 0.03)
        func decision(_ windows: [Gaze.Window], eligible: Set<UInt32>) -> Gaze.CandidateDecision {
            Gaze.candidateDecision(point: p, radius: radius, screen: screen,
                                   windows: windows, eligible: eligible)
        }
        let covering = Gaze.Window(id: 4, bounds: left.bounds)
        #expect(decision([covering, left], eligible: [1]).reason == .ineligibleWindow)
        #expect(decision([covering, left], eligible: [1]).candidateID == nil)
        #expect(decision([covering, left], eligible: [1, 4]).candidateID == 4)
        #expect(decision([left, covering], eligible: [1]).candidateID == 1)
        let dialog = Gaze.Window(id: 9, bounds: CGRect(x: -3810, y: -74, width: 12, height: 12))
        #expect(decision([dialog, left], eligible: [1]).reason == .ineligibleWindow)
        #expect(decision([dialog, left], eligible: [1]).candidateID == nil)
        #expect(decision([dialog, left], eligible: [1, 9]).reason == .nearWindowEdge)
        #expect(decision([dialog, left], eligible: [1, 9]).candidateID == nil)
    }

    @Test("Validation gate does not accept a few good regions or high error")
    func gate() {
        func result(_ correct: Int, _ median: Double, _ p90: Double, _ coverage: Double) -> Gaze.Validation {
            Gaze.Validation(medianError: median, p90Error: p90, errorRadius: .zero,
                            correctRegions: correct, count: 6, coverage: coverage)
        }
        #expect(!result(4, 0.01, 0.02, 1).passed)
        #expect(!result(6, 0.11, 0.12, 1).passed)
        #expect(!result(6, 0.01, 0.19, 1).passed)
        #expect(!result(6, 0.01, 0.02, 0.79).passed)
        #expect(result(5, 0.05, 0.10, 0.9).passed)
    }
}
