// One player per podcast or video, shared by the chapter screen and the menu-bar panel, so playback keeps going
// (and stays in the same place) when you move between them. Only one thing plays at a time. What's playing shows on
// the lock screen, in Control Center and the menu bar's Now Playing, and headphone buttons play, pause, and skip.

import AVFoundation
import Foundation
import MediaPlayer
import Observation

@MainActor @Observable
final class MediaCenter {
    static let shared = MediaCenter()

    private(set) var times: [URL: Double] = [:]
    private(set) var durations: [URL: Double] = [:]
    private(set) var playing: Set<URL> = []
    @ObservationIgnored private var players: [URL: AVPlayer] = [:]
    @ObservationIgnored private var observers: [URL: Any] = [:]
    /// Each file's modification date when its player was made: a remade podcast gets a fresh player.
    @ObservationIgnored private var madeFrom: [URL: Date] = [:]
    @ObservationIgnored private var lastUsed: [URL: Date] = [:]
    /// What the system shows for each file (chapter and book), and the file the system's controls act on.
    @ObservationIgnored private var titles: [URL: (title: String, artist: String?)] = [:]
    @ObservationIgnored private var current: URL?
    @ObservationIgnored private var commandsReady = false
    static let keepAtMost = 6
    static let skipSeconds = 15.0

    func player(for url: URL) -> AVPlayer {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        lastUsed[url] = Date()
        if let player = players[url], madeFrom[url] == modified { return player }
        forget(url)
        setUpRemoteCommands()
        let player = AVPlayer(url: url)
        players[url] = player
        madeFrom[url] = modified
        DispatchQueue.main.async { [weak self] in self?.trim() }  // not during a view update
        // Fires every quarter second while playing, and whenever playback starts, stops, or jumps.
        observers[url] = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated { self?.update(url, time: time.seconds) }
        }
        Task { [weak self] in
            if let seconds = try? await player.currentItem?.asset.load(.duration).seconds, seconds.isFinite {
                self?.durations[url] = seconds
            }
        }
        return player
    }

    /// Lets go of a player and its observer.
    private func forget(_ url: URL) {
        guard let player = players[url] else { return }
        player.pause()
        if let observer = observers[url] { player.removeTimeObserver(observer) }
        (players[url], observers[url], madeFrom[url], durations[url]) = (nil, nil, nil, nil)
        playing.remove(url)
        if current == url { publishNowPlaying() }
    }

    /// Stops and lets go of every player for a file inside this folder (a book that was removed).
    func forget(folder: URL) {
        let base = folder.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let inside = Set(players.keys).union(times.keys).union(titles.keys).filter { $0.standardizedFileURL.path.hasPrefix(prefix) }
        for url in inside {
            forget(url)
            (times[url], titles[url], lastUsed[url]) = (nil, nil, nil)
            if current == url { current = nil }
        }
        if !inside.isEmpty { publishNowPlaying() }
    }

    /// The title (the chapter) and artist (the book) the lock screen and Control Center show for this file.
    func setNowPlaying(_ url: URL, title: String, artist: String?) {
        guard titles[url]?.title != title || titles[url]?.artist != artist else { return }
        titles[url] = (title, artist)
        if current == url { publishNowPlaying() }
    }

    /// Keeps memory small: the least recently used players that aren't playing are released.
    private func trim() {
        let idle = players.keys.filter { !playing.contains($0) }.sorted { (lastUsed[$0] ?? .distantPast) < (lastUsed[$1] ?? .distantPast) }
        for url in idle.prefix(max(0, players.count - Self.keepAtMost)) { forget(url) }
    }

    func isPlaying(_ url: URL) -> Bool { playing.contains(url) }
    func time(_ url: URL) -> Double { times[url] ?? 0 }
    func duration(_ url: URL) -> Double { durations[url] ?? 0 }

    func toggle(_ url: URL) { isPlaying(url) ? player(for: url).pause() : player(for: url).play() }

    func seek(_ url: URL, to seconds: Double, play: Bool = true) {
        let player = player(for: url)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        times[url] = seconds
        if play { player.play() }
        if current == url { publishNowPlaying() }
    }

    private func update(_ url: URL, time: Double) {
        guard let player = players[url] else { return }
        if time.isFinite { times[url] = time }
        let wasPlaying = playing.contains(url)
        if player.rate > 0 {
            if !wasPlaying {
                // Something new started (here or in a video's own controls): quiet everything else.
                for (other, otherPlayer) in players where other != url { otherPlayer.pause() }
                playing = [url]
                current = url
            }
        } else {
            playing.remove(url)
        }
        if durations[url] == nil, let seconds = player.currentItem?.duration.seconds, seconds.isFinite { durations[url] = seconds }
        if wasPlaying != playing.contains(url) { publishNowPlaying() }
    }

    // MARK: the system's Now Playing and remote controls

    /// Lock screen, Control Center, the Mac's Now Playing, and AirPods act on the file that played last.
    private func setUpRemoteCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let center = MPRemoteCommandCenter.shared()
        // The system may call these off the main thread, so each one hops to the main actor.
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MediaCenter, URL) -> Void) {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                Task { @MainActor in if let self, let url = self.current { action(self, url) } }
                return .success
            }
        }
        on(center.playCommand) { media, url in media.player(for: url).play() }
        on(center.pauseCommand) { media, url in media.player(for: url).pause() }
        on(center.togglePlayPauseCommand) { media, url in media.toggle(url) }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        on(center.skipForwardCommand) { media, url in media.skip(url, by: Self.skipSeconds) }
        on(center.skipBackwardCommand) { media, url in media.skip(url, by: -Self.skipSeconds) }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in if let self, let url = self.current { self.seek(url, to: position, play: self.isPlaying(url)) } }
            return .success
        }
    }

    private func skip(_ url: URL, by seconds: Double) {
        let end = duration(url) > 0 ? duration(url) : .greatestFiniteMagnitude
        seek(url, to: min(max(0, time(url) + seconds), end), play: isPlaying(url))
    }

    private func publishNowPlaying() {
        let info = MPNowPlayingInfoCenter.default()
        guard let url = current, players[url] != nil else {
            info.nowPlayingInfo = nil
            #if os(macOS)
            info.playbackState = .stopped
            #endif
            return
        }
        let playingNow = isPlaying(url)
        var details: [String: Any] = [
            MPMediaItemPropertyTitle: titles[url]?.title ?? "NeuralLoop",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time(url),
            MPNowPlayingInfoPropertyPlaybackRate: playingNow ? 1.0 : 0.0,
        ]
        if let artist = titles[url]?.artist { details[MPMediaItemPropertyArtist] = artist }
        if duration(url) > 0 { details[MPMediaItemPropertyPlaybackDuration] = duration(url) }
        info.nowPlayingInfo = details
        #if os(macOS)
        info.playbackState = playingNow ? .playing : .paused
        #endif
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
