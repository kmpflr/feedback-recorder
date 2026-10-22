import Foundation

/// Something that is wrong with one side of a recording while the session runs.
public enum HealthIssue: String, Sendable, Hashable, CaseIterable, Codable {
    /// Buffers stopped arriving on a side that had been delivering.
    case noAudio
    /// The side's recording is not keeping pace with real time (see `CaptureRateMonitor`).
    case wrongRate
    /// The side has said nothing for a while although the other side was talking.
    case silentWhileOtherTalks
    /// The side carries speech but the transcriber has produced nothing from it.
    case noTranscript
    /// Nothing has ever been heard on this side of a two-sided session while the other side carried
    /// the conversation — half of it is not being recorded at all.
    case oneSidedRecording

    /// Whether the condition only means anything on a side the session has already heard from.
    /// A capture at the wrong rate is broken whether or not anyone has spoken into it yet, and a
    /// side being missing altogether is by definition about a side nobody has been heard on.
    var requiresHeardSide: Bool { self != .wrongRate && self != .oneSidedRecording }
}

public struct HealthChange: Sendable, Equatable {
    public var channel: Channel
    public var issue: HealthIssue
    public var raised: Bool
    public var text: String
}

public struct HealthSnapshot: Sendable, Equatable {
    /// Which sides the session has heard speech from, for the icon: a session nobody has spoken
    /// into, one where only the microphone has carried speech, one where only system audio has,
    /// and one where both have each read differently.
    public enum Presentation: Sendable, Equatable { case nothingHeard, micOnly, systemAudioOnly, bothSides }

    public var channels: [Channel]
    public var heard: Set<Channel>
    public var issues: [Channel: Set<HealthIssue>]
    /// One line per active issue, in channel order, ready for a menu header.
    public var problems: [String]

    public var isHealthy: Bool { problems.isEmpty }
    public var unheard: [Channel] { channels.filter { !heard.contains($0) } }

    public var presentation: Presentation {
        let mic = heard.contains(.me) || heard.contains(.room)
        let system = heard.contains(.them)
        switch (mic, system) {
        case (false, false): return .nothingHeard
        case (true, false): return .micOnly
        case (false, true): return .systemAudioOnly
        case (true, true): return .bothSides
        }
    }
}

/// Tells, per side of a session, whether that side is still being recorded usefully.
///
/// Every signal it works from can look healthy on its own: buffers arrive, levels move, files
/// grow. What gives a dead side away is the shape of the session around it — one side talking for
/// minutes while the other never makes a sound, speech that never turns into a transcript line, a
/// side that delivered and then stopped. Each is a per-channel issue that is raised once and
/// cleared once, so a caller can turn the transitions into notes and notifications and the current
/// state into an icon.
///
/// Silence on a previously heard side and a side that was never heard are distinct issues.
/// Call mode warns about a missing side once the other side has carried enough conversation;
/// room mode deliberately uses only the microphone.
///
/// The transcriber is the speech detector of first resort: a side is heard the moment its first
/// segment lands, and how much a side has talked is the length of what was transcribed from it. A
/// level gate is only the fallback for a side whose transcriber has stopped, and it is relative:
/// each side's noise floor is tracked and a buffer counts as speech when it clears that floor by
/// `speechMarginDB`. On a built-in MacBook microphone silence sits near −50 dBFS and speech peaks
/// only 10–14 dB above it, so no fixed dBFS gate can tell the two apart across microphones.
public struct ChannelHealth: Sendable {
    public let channels: [Channel]
    /// How long one side may stay silent while the other talks before that is worth raising.
    /// `nil` switches the rule off.
    public let asymmetryPeriod: TimeInterval?
    /// How far above its own noise floor a buffer has to be to count as speech-level audio.
    public let speechMarginDB: Double
    /// How fast the floor estimate drifts upward when levels stay above it, in dB per second of
    /// audio. It snaps down at once, so speech that dips between words keeps the floor honest.
    public let floorRiseDBPerSecond: Double
    /// Speech-level audio needed to arm a side without a transcript, counted within `armWindow`.
    public let armSeconds: TimeInterval
    /// How far back speech-level audio counts toward arming a side. Without a bound the total runs
    /// for the whole session, and sounds minutes apart — three chimes through a system-audio tap —
    /// add up to a side the session then expects to keep hearing from.
    public let armWindow: TimeInterval
    /// How many separate stretches of speech-level audio arming takes. Loudness alone cannot tell a
    /// voice from a tone, so the shape has to: talking starts and stops at syllable rate, while a
    /// chime, a ding or a hum is one unbroken stretch however long and however loud.
    public let armOnsets: Int
    /// How much the other side has to have said, since this side last spoke, for the silence to
    /// count as one-sided rather than as a pause both sides are taking.
    public let otherSpeechSeconds: TimeInterval
    public let noTranscriptSeconds: TimeInterval
    /// How far above its floor a side has to be to fill a level meter completely.
    public let meterRangeDB: Double

    /// One unbroken stretch of speech-level audio on a side.
    private struct GatedRun { var start: TimeInterval; var end: TimeInterval }

    private var floor: [Channel: Double] = [:]
    /// Recent stretches of speech-level audio per side, newest last, pruned to `armWindow`.
    private var gatedRuns: [Channel: [GatedRun]] = [:]
    /// Whether the side's last buffer was itself speech-level, so the next one either extends that
    /// stretch or starts a new one.
    private var runIsOpen: [Channel: Bool] = [:]
    private var gatedSinceSegment: [Channel: TimeInterval] = [:]
    private var transcribedSeconds: [Channel: TimeInterval] = [:]
    private var lastSpeech: [Channel: TimeInterval] = [:]
    private var otherTranscribedAtLastSpeech: [Channel: TimeInterval] = [:]
    /// The sides heard so far. Cheaper to compare than a whole snapshot when a caller wants to
    /// know whether the icon has anything new to show.
    public private(set) var heard: Set<Channel> = []
    private var issues: [Channel: Set<HealthIssue>]

    public init(channels: [Channel], asymmetryPeriod: TimeInterval?, speechMarginDB: Double = 10,
                floorRiseDBPerSecond: Double = 2, armSeconds: TimeInterval = 3,
                armWindow: TimeInterval = 60, armOnsets: Int = 3,
                otherSpeechSeconds: TimeInterval = 30, noTranscriptSeconds: TimeInterval = 45,
                meterRangeDB: Double = 25) {
        self.channels = channels; self.asymmetryPeriod = asymmetryPeriod
        self.speechMarginDB = speechMarginDB; self.floorRiseDBPerSecond = floorRiseDBPerSecond
        self.armSeconds = armSeconds; self.armWindow = armWindow; self.armOnsets = armOnsets
        self.otherSpeechSeconds = otherSpeechSeconds
        self.noTranscriptSeconds = noTranscriptSeconds; self.meterRangeDB = meterRangeDB
        self.issues = Dictionary(uniqueKeysWithValues: channels.map { ($0, []) })
    }

    /// Where `levelDBFS` sits between the side's noise floor (0) and `meterRangeDB` above it (1),
    /// so a level meter reads the same on a quiet built-in microphone as on a hot headset. A side
    /// with no floor yet — nothing has arrived on it — reads 0.
    public func meterFraction(channel: Channel, levelDBFS: Double) -> Double {
        guard let floor = floor[channel] else { return 0 }
        return min(1, max(0, (levelDBFS - floor) / meterRangeDB))
    }

    public var snapshot: HealthSnapshot {
        let problems = channels.flatMap { channel in
            HealthIssue.allCases.filter { issues[channel]?.contains($0) == true }
                .map { text($0, on: channel, raised: true) }
        }
        return HealthSnapshot(channels: channels, heard: heard, issues: issues, problems: problems)
    }

    /// A buffer covering `audioSeconds` at `levelDBFS` arrived on `channel` at session time `time`.
    public mutating func observeAudio(channel: Channel, levelDBFS: Double, audioSeconds: TimeInterval,
                                      at time: TimeInterval) -> [HealthChange] {
        var changes: [HealthChange] = []
        // The first buffer sets the floor, so a fan already running at start is the floor and
        // not an hour of speech. After that the floor follows every dip at once and climbs slowly.
        let floorNow = floor[channel].map { min($0 + floorRiseDBPerSecond * audioSeconds, levelDBFS) } ?? levelDBFS
        floor[channel] = floorNow
        let aboveFloor = levelDBFS > floorNow + speechMarginDB
        if aboveFloor {
            gatedSinceSegment[channel, default: 0] += audioSeconds
            extendGatedRun(on: channel, at: time, audioSeconds: audioSeconds)
        } else {
            runIsOpen[channel] = false
        }
        pruneGatedRuns(on: channel, before: time - armWindow)
        // Only audio that looks like talking counts as the side speaking. Anything less is a sound
        // the tap happened to catch, and treating it as speech is what let a chime arm a side and
        // then, minutes later, report that side as having resumed.
        if aboveFloor, soundsLikeSpeech(on: channel, at: time) {
            changes += markHeard(channel)
            changes += noteSpeech(on: channel, at: time)
        }
        if aboveFloor, heard.contains(channel), gatedSinceSegment[channel, default: 0] >= noTranscriptSeconds {
            changes += update(.noTranscript, on: channel, true)
        }
        changes += evaluateAsymmetry(at: time)
        return changes
    }

    /// Forgets a side's noise floor, so the next buffer sets it afresh. For a device change: the
    /// new microphone's room is not speech on the old one's floor, and its first buffers would
    /// otherwise read as a filled meter or as arming audio.
    public mutating func resetFloor(channel: Channel) {
        floor[channel] = nil
        // The stretches measured against the old floor say nothing about the new device, and
        // keeping them would let audio from before the change arm the side after it.
        gatedRuns[channel] = []
        runIsOpen[channel] = false
    }

    /// A transcript segment for `channel`, spanning `start`…`end` in session seconds.
    public mutating func observeSegment(channel: Channel, start: TimeInterval, end: TimeInterval) -> [HealthChange] {
        var changes = markHeard(channel)
        transcribedSeconds[channel, default: 0] += max(0, end - start)
        gatedSinceSegment[channel] = 0
        changes += noteSpeech(on: channel, at: max(end, lastSpeech[channel] ?? 0))
        changes += update(.noTranscript, on: channel, false)
        changes += evaluateAsymmetry(at: end)
        return changes
    }

    /// Session time moved on without a buffer to say so. A side that has stopped delivering
    /// altogether never re-evaluates itself, so the session ticker asks on its behalf.
    public mutating func observeTime(_ time: TimeInterval) -> [HealthChange] {
        evaluateAsymmetry(at: time)
    }

    /// Raises or clears a condition detected elsewhere in the session. Raising one that only means
    /// something on a heard side is ignored for a side that has never spoken.
    public mutating func set(_ issue: HealthIssue, on channel: Channel, _ active: Bool) -> [HealthChange] {
        if active, issue.requiresHeardSide, !heard.contains(channel) { return [] }
        return update(issue, on: channel, active)
    }

    // MARK: private

    private func other(of channel: Channel) -> Channel? { channels.first { $0 != channel } }

    /// Records that a side has now been heard. A side the session had given up on is no longer
    /// missing, so whatever was said about it being missing is withdrawn in the same breath.
    private mutating func markHeard(_ channel: Channel) -> [HealthChange] {
        guard heard.insert(channel).inserted else { return [] }
        return update(.oneSidedRecording, on: channel, false)
    }

    /// Adds `audioSeconds` of speech-level audio to the side's current stretch, or opens a new one
    /// when the buffer before it was below the gate.
    private mutating func extendGatedRun(on channel: Channel, at time: TimeInterval, audioSeconds: TimeInterval) {
        var runs = gatedRuns[channel, default: []]
        if runIsOpen[channel] == true, !runs.isEmpty {
            runs[runs.count - 1].end = Swift.max(runs[runs.count - 1].end, time + audioSeconds)
        } else {
            runs.append(GatedRun(start: time, end: time + audioSeconds))
        }
        gatedRuns[channel] = runs
        runIsOpen[channel] = true
    }

    /// Drops stretches that have fallen out of `armWindow`. Runs are appended in time order, so the
    /// stale ones are a prefix and the common case — nothing to drop — costs one comparison rather
    /// than a copy of the whole array on every buffer.
    private mutating func pruneGatedRuns(on channel: Channel, before cutoff: TimeInterval) {
        guard let runs = gatedRuns[channel], let first = runs.first, first.end <= cutoff else { return }
        gatedRuns[channel] = Array(runs.drop { $0.end <= cutoff })
    }

    /// Whether the side's recent audio has the shape of someone talking: `armSeconds` of it above
    /// the floor, arriving in at least `armOnsets` separate stretches, all within `armWindow`.
    ///
    /// Level alone cannot carry this. A tap recording digital silence has its floor pinned at the
    /// −120 dBFS clamp, so every audible sound clears a gate set `speechMarginDB` above it, and a
    /// join tone is several seconds of exactly that. What separates the two is the shape: talking
    /// breaks between syllables and words, a tone does not.
    private func soundsLikeSpeech(on channel: Channel, at time: TimeInterval) -> Bool {
        let runs = gatedRuns[channel, default: []]
        guard runs.count >= armOnsets else { return false }
        let cutoff = time - armWindow
        let total = runs.reduce(0.0) { $0 + Swift.max(0, $1.end - Swift.max($1.start, cutoff)) }
        return total >= armSeconds
    }

    /// The side spoke at `time`: it is no longer the silent one, and the other side's talking is
    /// counted afresh from here.
    private mutating func noteSpeech(on channel: Channel, at time: TimeInterval) -> [HealthChange] {
        lastSpeech[channel] = time
        if let other = other(of: channel) { otherTranscribedAtLastSpeech[channel] = transcribedSeconds[other, default: 0] }
        return update(.silentWhileOtherTalks, on: channel, false)
    }

    private mutating func evaluateAsymmetry(at time: TimeInterval) -> [HealthChange] {
        guard let period = asymmetryPeriod else { return [] }
        var changes: [HealthChange] = []
        // A side nobody has been heard on, in a session that has two of them, once the other side
        // has carried the conversation for long enough that the absence cannot be a lull. The tap
        // may be recording exactly what reaches it and still be recording half a conversation.
        for channel in channels where !heard.contains(channel) {
            guard let other = other(of: channel), heard.contains(other) else { continue }
            if time >= period, transcribedSeconds[other, default: 0] >= otherSpeechSeconds {
                changes += update(.oneSidedRecording, on: channel, true)
            }
        }
        for channel in channels where heard.contains(channel) {
            // A side that has stopped delivering is already reported as such; saying it is also
            // silent would be the same failure twice.
            guard let other = other(of: channel), issues[channel]?.contains(.noAudio) != true else { continue }
            let quietFor = time - lastSpeech[channel, default: 0]
            let otherTalked = transcribedSeconds[other, default: 0] - otherTranscribedAtLastSpeech[channel, default: 0]
            if quietFor >= period, otherTalked >= otherSpeechSeconds {
                changes += update(.silentWhileOtherTalks, on: channel, true)
            }
        }
        return changes
    }

    private mutating func update(_ issue: HealthIssue, on channel: Channel, _ active: Bool) -> [HealthChange] {
        var current = issues[channel, default: []]
        guard current.contains(issue) != active else { return [] }
        if active { current.insert(issue) } else { current.remove(issue) }
        issues[channel] = current
        return [HealthChange(channel: channel, issue: issue, raised: active, text: text(issue, on: channel, raised: active))]
    }

    private func text(_ issue: HealthIssue, on channel: Channel, raised: Bool) -> String {
        let side = channel.label
        switch (issue, raised) {
        case (.noAudio, true): return "\(side) audio stopped delivering"
        case (.noAudio, false): return "\(side) audio resumed"
        case (.wrongRate, true): return "\(side) audio is recording out of step with real time"
        case (.wrongRate, false): return "\(side) audio is back in step with real time"
        case (.silentWhileOtherTalks, true):
            let otherSide = other(of: channel)?.label ?? "the other side"
            return "\(side): no speech for \(Self.describe(asymmetryPeriod ?? 0)) while \(otherSide) talked"
        case (.silentWhileOtherTalks, false): return "\(side): speech resumed"
        case (.noTranscript, true): return "\(side): \(Int(noTranscriptSeconds)) s of speech with nothing transcribed"
        case (.noTranscript, false): return "\(side): transcription resumed"
        case (.oneSidedRecording, true):
            // Deliberately not naming the other side: when this fires the microphone's lines are
            // relabelled Room, and a note frozen with the old name would contradict them.
            return "\(side): nothing recorded on this side, the microphone carried the whole call"
        case (.oneSidedRecording, false): return "\(side): recording on this side now"
        }
    }

    private static func describe(_ period: TimeInterval) -> String {
        period >= 60 && period.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(period / 60)) min" : "\(Int(period)) s"
    }
}
