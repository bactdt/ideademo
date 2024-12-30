//
//  music_webApp.swift
//  music_web
//
//  Created by txg on 2024/12/30.
//

import SwiftUI
import AVFoundation
import MediaPlayer

@main
struct music_webApp: App {
    init() {
        configureAudioSession()
        setupNowPlayingInfo()
    }

    func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
    }

    func setupNowPlayingInfo() {
        let nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: "Your Song Title",
            MPMediaItemPropertyArtist: "Artist Name",
            MPMediaItemPropertyPlaybackDuration: 300, // Duration in seconds
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0, // Current playback time
            MPNowPlayingInfoPropertyPlaybackRate: 1.0 // Playback rate
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
