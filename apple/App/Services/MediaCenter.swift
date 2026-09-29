// One player per podcast or video, shared by the chapter screen and the menu-bar panel, so playback keeps going
// (and stays in the same place) when you move between them. Only one thing plays at a time.

import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class MediaCenter {
    static let shared = MediaCenter()

    private(set) var times: [URL: Double] = [:]
    private(set) var durations: [URL: Double] = [:]
    private(set) var playing: Set<URL> = []
    @ObservationIgnored private var players: [URL: AVPlayer] = [:]
    @ObservationIgnored private var observers: [URL: Any] = [:]

    func player(for url: URL) -> AVPlayer {
        if let player = players[url] { return player }
        let player = AVPlayer(url: url)
        players[url] = player
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

    func isPlaying(_ url: URL) -> Bool { playing.contains(url) }
    func time(_ url: URL) -> Double { times[url] ?? 0 }
    func duration(_ url: URL) -> Double { durations[url] ?? 0 }

    func toggle(_ url: URL) { isPlaying(url) ? player(for: url).pause() : player(for: url).play() }

    func seek(_ url: URL, to seconds: Double, play: Bool = true) {
        let player = player(for: url)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        times[url] = seconds
        if play { player.play() }
    }

    private func update(_ url: URL, time: Double) {
        guard let player = players[url] else { return }
        if time.isFinite { times[url] = time }
        if player.rate > 0 {
            if !playing.contains(url) {
                // Something new started (here or in a video's own controls): quiet everything else.
                for (other, otherPlayer) in players where other != url { otherPlayer.pause() }
                playing = [url]
            }
        } else {
            playing.remove(url)
        }
        if durations[url] == nil, let seconds = player.currentItem?.duration.seconds, seconds.isFinite { durations[url] = seconds }
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
