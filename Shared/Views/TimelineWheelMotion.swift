#if os(iOS)
import SwiftUI
import QuartzCore

/// Local presentation physics. A display link runs only during a gesture or settling.
@MainActor @Observable final class TimelineWheelMotion {
    private(set) var position: CGFloat = 0
    private(set) var thumbOffset: CGFloat = 0
    private(set) var focusedIndex = 0
    private(set) var isScrubbing = false
    private(set) var selectionTick = 0
    private(set) var dayTick = 0
    private(set) var edgeTick = 0
    private(set) var readingEmphasis: CGFloat = 0

    @ObservationIgnored private var anchors: [CGFloat] = []
    @ObservationIgnored private var ids: [UUID] = []
    @ObservationIgnored private var eventIndices: [UUID: Int] = [:]
    @ObservationIgnored private var days: [Date] = []
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var clockTarget: TimelineWheelClock?
    @ObservationIgnored private var previousTimestamp: CFTimeInterval = 0
    @ObservationIgnored private var lastFeedback: CFTimeInterval = 0
    @ObservationIgnored private var lastRelease: CFTimeInterval = 0
    @ObservationIgnored private var velocity: CGFloat = 0
    @ObservationIgnored private var thumbVelocity: CGFloat = 0
    @ObservationIgnored private var control: CGFloat = 0
    @ObservationIgnored private var dragOrigin: CGFloat?
    @ObservationIgnored private var target: CGFloat?
    @ObservationIgnored private var atBoundary = false
    @ObservationIgnored private var reduceMotion = false

    var acceptsTap: Bool { dragOrigin == nil && !isScrubbing && CACurrentMediaTime() - lastRelease > 0.18 }

    func isCentered(at anchor: CGFloat) -> Bool {
        abs(position - anchor) < 8 && abs(velocity) < 30 && dragOrigin == nil && !isScrubbing
    }

    /// Callbacks use the current model, so cached card content cannot retain an old index.
    func prepareToOpen(_ recordID: UUID) -> Bool {
        guard acceptsTap, let index = eventIndices[recordID], anchors.indices.contains(index) else { return false }
        guard isCentered(at: anchors[index]) else { move(to: index); return false }
        stop()
        return true
    }

    func configure(_ presentation: TimelinePresentation, layout: TimelineWheelLayout, reduceMotion: Bool) {
        let oldID = ids.indices.contains(focusedIndex) ? ids[focusedIndex] : nil
        stop()
        self.reduceMotion = reduceMotion
        ids = presentation.groups.map(\.id)
        eventIndices = Dictionary(uniqueKeysWithValues: presentation.groups.enumerated().flatMap { index, group in
            group.events.map { ($0.id, index) }
        })
        days = presentation.groups.map { presentation.calendar.startOfDay(for: $0.date) }
        anchors = layout.anchors
        focusedIndex = oldID.flatMap { ids.firstIndex(of: $0) } ?? presentation.initialIndex()
        position = anchors.indices.contains(focusedIndex) ? anchors[focusedIndex] : 0
    }

    func scrub(translation: CGFloat, travel: CGFloat) {
        guard anchors.count > 1 else { return }
        if !isScrubbing {
            dragOrigin = nil; target = nil; velocity = 0; thumbVelocity = 0
            isScrubbing = true
        }
        let travel = max(1, travel)
        control = min(1, max(-1, translation / travel))
        // The last few points resist the finger instead of hitting a rigid stop.
        let excess = max(0, abs(translation) - travel)
        thumbOffset = min(travel, abs(translation)) * (translation < 0 ? -1 : 1)
            + (translation < 0 ? -1 : 1) * 14 * (1 - exp(-excess / 55))
        run()
    }

    func releaseScrubber() {
        guard isScrubbing else { return }
        // A quick flick can end before the display link has accelerated fully.
        let magnitude = abs(control)
        let impulse = (control < 0 ? -1.0 : 1.0) * (32 * magnitude + 1650 * pow(magnitude, 3.2)) * 0.45
        if velocity * impulse < 0 || abs(velocity) < abs(impulse) { velocity = impulse }
        isScrubbing = false; control = 0; lastRelease = CACurrentMediaTime()
        if reduceMotion { thumbOffset = 0 }
        run()
    }

    func drag(translation: CGFloat) {
        guard anchors.count > 1 else { return }
        if dragOrigin == nil {
            stopClock(); velocity = 0; target = nil; isScrubbing = false; thumbOffset = 0
            dragOrigin = position
        }
        let proposed = (dragOrigin ?? position) - translation
        let bounded = clamped(proposed)
        let excess = proposed - bounded
        position = bounded + (excess < 0 ? -1 : 1) * 64 * (1 - exp(-abs(excess) / 150))
        updateFocus()
        run()
    }

    func releaseDrag(velocity: CGFloat) {
        guard dragOrigin != nil else { return }
        dragOrigin = nil; lastRelease = CACurrentMediaTime()
        self.velocity = min(2400, max(-2400, -velocity))
        if reduceMotion { self.velocity *= 0.35 }
        run()
    }

    func move(to index: Int) {
        guard anchors.indices.contains(index) else { return }
        dragOrigin = nil; isScrubbing = false; control = 0; velocity = 0
        target = anchors[index]
        if reduceMotion {
            position = anchors[index]; thumbOffset = 0; updateFocus(); stopClock()
        } else {
            run()
        }
    }

    func stop() {
        stopClock()
        velocity = 0; thumbVelocity = 0; control = 0; thumbOffset = 0
        isScrubbing = false; dragOrigin = nil; target = nil
        readingEmphasis = 0
    }

    private func run() {
        guard displayLink == nil else { return }
        let clock = TimelineWheelClock(self)
        let link = CADisplayLink(target: clock, selector: #selector(TimelineWheelClock.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        clockTarget = clock; displayLink = link; previousTimestamp = 0
        link.add(to: .main, forMode: .common)
    }

    private func stopClock() {
        displayLink?.invalidate(); displayLink = nil; clockTarget = nil; previousTimestamp = 0
    }

    fileprivate func frame(_ link: CADisplayLink) {
        let dt = CGFloat(min(1.0 / 30, max(1.0 / 240,
            previousTimestamp == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - previousTimestamp)))
        previousTimestamp = link.timestamp
        if dragOrigin != nil {
            // The gesture owns position; the clock only eases the reading treatment.
        } else if isScrubbing {
            let magnitude = abs(control)
            let speed = (control < 0 ? -1.0 : 1.0) * (32 * magnitude + 1650 * pow(magnitude, 3.2))
            velocity += (speed - velocity) * (1 - exp(-dt / 0.10))
            let proposed = position + velocity * dt
            position = clamped(proposed)
            let boundary = abs(proposed - position) > 0.5
            if boundary && !atBoundary { edgeTick &+= 1 }
            atBoundary = boundary
            if boundary { velocity = 0 }
        } else {
            // A damped spring returns the thumb independently of the cards' inertia.
            thumbVelocity += (-250 * thumbOffset - 27 * thumbVelocity) * dt
            thumbOffset += thumbVelocity * dt
            if target == nil {
                if position < 0 || position > (anchors.last ?? 0) {
                    target = clamped(position)
                } else {
                    position += velocity * dt
                    velocity *= exp(-(reduceMotion ? 9 : 4.6) * dt)
                    if abs(velocity) < 85 { target = nearestAnchor(to: position + velocity * 0.12) }
                }
            }
            if let target {
                velocity += ((target - position) * 165 - 25 * velocity) * dt
                position += velocity * dt
                if abs(position - target) < 0.15 && abs(velocity) < 1 {
                    position = target; velocity = 0
                }
            }
        }
        updateFocus()
        updateReadingEmphasis(dt: dt)
        if dragOrigin != nil, readingEmphasis == 1 {
            stopClock()
        } else if isScrubbing, readingEmphasis == 1, abs(velocity) < 1,
                  abs(control) < 0.001 || atBoundary {
            // A held, centered thumb or reached edge has nothing left to animate.
            // The next gesture update restarts the clock if direction/speed changes.
            velocity = 0
            stopClock()
        } else if dragOrigin == nil, !isScrubbing, velocity == 0,
                  abs(thumbOffset) < 0.15, abs(thumbVelocity) < 1, readingEmphasis == 0 {
            thumbOffset = 0; thumbVelocity = 0; target = nil; stopClock()
        }
    }

    private func updateReadingEmphasis(dt: CGFloat) {
        let speed = min(1, max(0, (abs(velocity) - 10) / 170))
        let desired: CGFloat = dragOrigin != nil || isScrubbing ? 1 : speed * speed * (3 - 2 * speed)
        let response: CGFloat = desired > readingEmphasis ? 0.045 : 0.22
        var next = readingEmphasis + (desired - readingEmphasis) * (1 - exp(-dt / response))
        if abs(next - desired) < 0.005 { next = desired }
        if next != readingEmphasis { readingEmphasis = next }
    }

    private func clamped(_ value: CGFloat) -> CGFloat { min(anchors.last ?? 0, max(0, value)) }

    private func nearestIndex(to value: CGFloat) -> Int {
        guard !anchors.isEmpty else { return 0 }
        var low = 0, high = anchors.count - 1
        while low < high {
            let middle = (low + high) / 2
            if anchors[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low > 0 && abs(anchors[low - 1] - value) < abs(anchors[low] - value) ? low - 1 : low
    }

    private func nearestAnchor(to value: CGFloat) -> CGFloat { anchors.isEmpty ? 0 : anchors[nearestIndex(to: value)] }

    private func updateFocus() {
        let index = nearestIndex(to: position)
        guard index != focusedIndex else { return }
        let previous = focusedIndex
        focusedIndex = index
        let now = CACurrentMediaTime()
        // Fast scrubbing must not generate an unbroken buzz.
        guard now - lastFeedback > 0.095 else { return }
        lastFeedback = now
        if days.indices.contains(previous), days.indices.contains(index), days[previous] != days[index] {
            dayTick &+= 1
        } else {
            selectionTick &+= 1
        }
    }
}

/// CADisplayLink retains its target; the weak owner prevents an offscreen retain cycle.
@MainActor private final class TimelineWheelClock: NSObject {
    weak var owner: TimelineWheelMotion?
    init(_ owner: TimelineWheelMotion) { self.owner = owner }
    @objc func frame(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.frame(link)
    }
}
#endif
