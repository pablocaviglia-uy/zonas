import Foundation
import CoreGraphics

/// The experimental estimator's decisions, without a camera, windows or AX writes.
enum Gaze {
    struct Features {
        // Eye coordinates are relative to each eye's width, not camera pixels.
        let values: [Double]
        static let count = 10
        var isValid: Bool { values.count == Self.count && values.allSatisfy(\.isFinite) }
    }

    static func eye(contour: [CGPoint], pupil: CGPoint) -> CGPoint? {
        guard contour.count >= 6, pupil.x.isFinite, pupil.y.isFinite,
              contour.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        // The longest chord is the eye axis, even when the head is tilted.
        var ends: (CGPoint, CGPoint) = (.zero, .zero)
        var width = 0.0
        for a in contour {
            for b in contour {
                let length = hypot(b.x - a.x, b.y - a.y)
                if length > width { width = length; ends = a.x < b.x ? (a, b) : (b, a) }
            }
        }
        guard width > 0.01 else { return nil }
        let dx = (ends.1.x - ends.0.x) / width, dy = (ends.1.y - ends.0.y) / width
        let mid = CGPoint(x: (ends.0.x + ends.1.x) / 2, y: (ends.0.y + ends.1.y) / 2)
        func project(_ p: CGPoint) -> CGPoint {
            let x = (p.x - mid.x) / width, y = (p.y - mid.y) / width
            return CGPoint(x: x * dx + y * dy, y: -x * dy + y * dx)
        }
        let points = contour.map(project)
        let opening = points.map(\.y).max()! - points.map(\.y).min()!
        let p = project(pupil)
        // Vision explicitly warns that pupils can be wrong during a blink.
        guard opening >= 0.10, opening <= 0.65, abs(p.x) < 0.55,
              abs(p.y) < opening / 2 + 0.04 else { return nil }
        return p
    }

    struct Group {
        let target: CGPoint // normalized screen coordinates, top-left origin
        let samples: [Features]
    }

    struct Collector {
        static let settlingTime = 0.9
        static let minimumDuration = 2.6
        static let timeout = 7.0
        static let minimumSamples = 18
        let began: Double
        private(set) var samples: [Features] = []
        private var lastTime = -Double.infinity
        init(began: Double) { self.began = began }
        mutating func add(_ features: Features?, at time: Double) {
            guard let features, features.isValid, time.isFinite, time > lastTime,
                  time - began >= Self.settlingTime, time - began <= Self.timeout, samples.count < 90 else { return }
            samples.append(features); lastTime = time
        }
        func timedOut(at time: Double) -> Bool { time - began > Self.timeout }
        func ready(at time: Double) -> Bool {
            time - began >= Self.minimumDuration && !timedOut(at: time) && samples.count >= Self.minimumSamples
        }
    }

    struct Model {
        let mean: [Double]
        let scale: [Double]
        let low: [Double]
        let high: [Double]
        let x: [Double]
        let y: [Double]

        func predict(_ features: Features) -> CGPoint? {
            guard features.isValid else { return nil }
            // A changed seating position needs calibration, not extrapolation.
            for i in 0..<Features.count {
                let margin = i < 4 ? 0.08 : (i < 7 ? 0.16 : 0.06)
                guard features.values[i] >= low[i] - margin,
                      features.values[i] <= high[i] + margin else { return nil }
            }
            let row = [1.0] + zip(zip(features.values, mean), scale).map { ($0.0.0 - $0.0.1) / $0.1 }
            let p = CGPoint(x: zip(row, x).reduce(0) { $0 + $1.0 * $1.1 },
                            y: zip(row, y).reduce(0) { $0 + $1.0 * $1.1 })
            guard p.x.isFinite, p.y.isFinite, (0...1).contains(p.x), (0...1).contains(p.y) else { return nil }
            return p
        }
    }

    static func fit(_ groups: [Group]) -> Model? {
        guard groups.count >= 9, groups.allSatisfy({ valid($0.target) && $0.samples.count >= 12
            && $0.samples.allSatisfy(\.isValid) }) else { return nil }
        let targets = groups.map(\.target)
        guard targets.map(\.x).max()! - targets.map(\.x).min()! > 0.65,
              targets.map(\.y).max()! - targets.map(\.y).min()! > 0.65 else { return nil }
        for i in targets.indices {
            for j in targets.indices where j > i {
                guard distance(targets[i], targets[j]) > 0.06 else { return nil }
            }
        }
        let all = groups.flatMap(\.samples).map(\.values)
        let mean = (0..<Features.count).map { i in all.map { $0[i] }.reduce(0, +) / Double(all.count) }
        let low = (0..<Features.count).map { i in all.map { $0[i] }.min()! }
        let high = (0..<Features.count).map { i in all.map { $0[i] }.max()! }
        // Flat pupil observations cannot identify a gaze model, even if a
        // person's head happens to follow every calibration dot perfectly.
        guard max(high[0] - low[0], high[2] - low[2]) > 0.035,
              max(high[1] - low[1], high[3] - low[3]) > 0.020 else { return nil }
        let scale = (0..<Features.count).map { i in
            max(0.015, sqrt(all.map { pow($0[i] - mean[i], 2) }.reduce(0, +) / Double(all.count)))
        }
        let n = Features.count + 1
        var matrix = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        var bx = Array(repeating: 0.0, count: n), by = bx
        for group in groups {
            // Equal target weight: a camera dropping frames at one corner must
            // not turn the centre into most of the training set.
            let weight = 1.0 / Double(group.samples.count)
            for features in group.samples {
                let row = [1.0] + (0..<Features.count).map { (features.values[$0] - mean[$0]) / scale[$0] }
                for i in 0..<n {
                    bx[i] += row[i] * group.target.x * weight
                    by[i] += row[i] * group.target.y * weight
                    for j in 0..<n { matrix[i][j] += row[i] * row[j] * weight }
                }
            }
        }
        for i in 1..<n { matrix[i][i] += 0.25 }
        guard let x = solve(matrix, bx), let y = solve(matrix, by) else { return nil }
        return Model(mean: mean, scale: scale, low: low, high: high, x: x, y: y)
    }

    struct Validation {
        let medianError: Double
        let p90Error: Double
        let errorRadius: CGSize
        let correctRegions: Int
        let count: Int
        let coverage: Double
        var passed: Bool { count >= 6 && coverage >= 0.8 && medianError <= 0.10
            && p90Error <= 0.18 && correctRegions >= Int(ceil(Double(count) * 0.8)) }
    }

    static func validate(_ model: Model, groups: [Group], trainingTargets: [CGPoint]) -> Validation? {
        // Validation dots must be unseen, rather than frames held out from the
        // very same dots: the latter conceals spatial overfitting.
        guard groups.count >= 6, groups.allSatisfy({ group in valid(group.target) && group.samples.count >= 12
            && group.samples.allSatisfy(\.isValid)
            && trainingTargets.allSatisfy { distance($0, group.target) > 0.06 } }),
              Set(groups.map { region($0.target) }).count == 6 else { return nil }
        var errors: [Double] = [], xs: [Double] = [], ys: [Double] = []
        var correct = 0, predicted = 0
        let total = groups.reduce(0) { $0 + $1.samples.count }
        for group in groups {
            let points = group.samples.compactMap(model.predict)
            predicted += points.count
            for sample in group.samples {
                guard let point = model.predict(sample) else { errors.append(1); continue }
                errors.append(distance(point, group.target))
                xs.append(abs(point.x - group.target.x)); ys.append(abs(point.y - group.target.y))
            }
            if points.count >= Int(ceil(Double(group.samples.count) * 0.8)) {
                let px = quantile(points.map { Double($0.x) }, 0.5)
                let py = quantile(points.map { Double($0.y) }, 0.5)
                let centre = CGPoint(x: px, y: py)
                if region(centre) == region(group.target) { correct += 1 }
            }
        }
        return Validation(medianError: quantile(errors, 0.5), p90Error: quantile(errors, 0.9),
                          errorRadius: CGSize(width: max(0.025, quantile(xs, 0.9)),
                                              height: max(0.025, quantile(ys, 0.9))),
                          correctRegions: correct, count: groups.count,
                          coverage: Double(predicted) / Double(total))
    }

    enum FixationState: Equatable {
        case missing, stale, collecting, unstable, stable
    }

    struct FixationDecision {
        let state: FixationState
        let progress: Double
        let stablePoint: CGPoint?
    }

    struct Fixation {
        private var points: [(time: Double, point: CGPoint)] = []
        mutating func reset() { points = [] }
        mutating func add(_ point: CGPoint?, at time: Double) {
            guard let point, valid(point), time.isFinite else { reset(); return }
            if let last = points.last,
               time <= last.time || time - last.time > 0.16 || distance(point, last.point) > 0.065 { reset() }
            points.append((time, point))
            points.removeAll { time - $0.time > 0.55 }
        }
        func stable(at now: Double) -> CGPoint? { decision(at: now).stablePoint }

        func decision(at now: Double) -> FixationDecision {
            guard let first = points.first, let last = points.last else {
                return FixationDecision(state: .missing, progress: 0, stablePoint: nil)
            }
            guard now.isFinite, now >= last.time, now - last.time <= 0.25 else {
                return FixationDecision(state: .stale, progress: 0, stablePoint: nil)
            }
            let duration = last.time - first.time
            let progress = min(1, min(duration / 0.30, Double(points.count) / 5))
            guard duration >= 0.30, points.count >= 5 else {
                return FixationDecision(state: .collecting, progress: progress, stablePoint: nil)
            }
            let centre = CGPoint(x: quantile(points.map { Double($0.point.x) }, 0.5),
                                 y: quantile(points.map { Double($0.point.y) }, 0.5))
            guard points.allSatisfy({ distance($0.point, centre) <= 0.045 }) else {
                return FixationDecision(state: .unstable, progress: 1, stablePoint: nil)
            }
            return FixationDecision(state: .stable, progress: 1, stablePoint: centre)
        }
    }

    struct Window {
        let id: UInt32
        let bounds: CGRect
    }

    enum CandidateReason: Equatable {
        case accepted, invalidInput, outsideDisplay, nearWindowEdge, ineligibleWindow, desktop
    }

    struct CandidateDecision {
        let candidateID: UInt32?
        let reason: CandidateReason
    }

    static func candidate(point: CGPoint, radius: CGSize, screen: CGRect,
                          windows: [Window], eligible: Set<UInt32>) -> UInt32? {
        candidateDecision(point: point, radius: radius, screen: screen,
                          windows: windows, eligible: eligible).candidateID
    }

    /// Front-to-back visible windows include blockers that are absent from
    /// Alt+Tab. All nine uncertainty probes must agree, including empty space.
    static func candidateDecision(point: CGPoint, radius: CGSize, screen: CGRect,
                                  windows: [Window], eligible: Set<UInt32>) -> CandidateDecision {
        func refused(_ reason: CandidateReason) -> CandidateDecision {
            CandidateDecision(candidateID: nil, reason: reason)
        }
        guard point.x.isFinite, point.y.isFinite, radius.width.isFinite, radius.height.isFinite,
              radius.width >= 0, radius.height >= 0, screen.width > 0, screen.height > 0,
              screen.minX.isFinite, screen.minY.isFinite, screen.width.isFinite, screen.height.isFinite else {
            return refused(.invalidInput)
        }
        guard valid(point) else { return refused(.outsideDisplay) }
        let centre = CGPoint(x: screen.minX + point.x * screen.width,
                             y: screen.minY + point.y * screen.height)
        let centreHasWindow = windows.contains { $0.bounds.contains(centre) }
        var candidate: UInt32?
        let errorBox = CGRect(x: screen.minX + (point.x - radius.width) * screen.width,
                              y: screen.minY + (point.y - radius.height) * screen.height,
                              width: 2 * radius.width * screen.width, height: 2 * radius.height * screen.height)
        for dx in [-1.0, 0, 1] {
            for dy in [-1.0, 0, 1] {
                let p = CGPoint(x: screen.minX + (point.x + dx * radius.width) * screen.width,
                                y: screen.minY + (point.y + dy * radius.height) * screen.height)
                guard screen.contains(p) else { return refused(.outsideDisplay) }
                guard let hit = windows.first(where: { $0.bounds.contains(p) }) else {
                    return refused(centreHasWindow ? .nearWindowEdge : .desktop)
                }
                guard eligible.contains(hit.id) else { return refused(.ineligibleWindow) }
                if let candidate, candidate != hit.id { return refused(.nearWindowEdge) }
                candidate = hit.id
            }
        }
        if let candidate, let index = windows.firstIndex(where: { $0.id == candidate }),
           let blocker = windows.prefix(index).first(where: { $0.bounds.intersects(errorBox) }) {
            return refused(eligible.contains(blocker.id) ? .nearWindowEdge : .ineligibleWindow)
        }
        return CandidateDecision(candidateID: candidate, reason: .accepted)
    }

    static func region(_ point: CGPoint) -> Int { min(2, Int(point.x * 3)) + 3 * min(1, Int(point.y * 2)) }
    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    static func valid(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite && (0...1).contains(p.x) && (0...1).contains(p.y) }
    static func quantile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 1 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    private static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        var a = zip(matrix, rhs).map { $0.0 + [$0.1] }
        let n = rhs.count
        for column in 0..<n {
            let pivot = (column..<n).max { abs(a[$0][column]) < abs(a[$1][column]) }!
            guard abs(a[pivot][column]) > 1e-10 else { return nil }
            a.swapAt(column, pivot)
            let divisor = a[column][column]
            for j in column...n { a[column][j] /= divisor }
            for i in 0..<n where i != column {
                let multiplier = a[i][column]
                for j in column...n { a[i][j] -= multiplier * a[column][j] }
            }
        }
        let answer = a.map { $0[n] }
        return answer.allSatisfy(\.isFinite) ? answer : nil
    }
}
