import Foundation
import AVFoundation

final class AudioManager {
    private var backgroundMusicPlayer: AVAudioPlayer?
    
    func loadBackgroundMusic(url: URL) {
        do {
            backgroundMusicPlayer = try AVAudioPlayer(contentsOf: url)
            backgroundMusicPlayer?.numberOfLoops = -1 // Infinite loop
            backgroundMusicPlayer?.volume = 0.1
            backgroundMusicPlayer?.prepareToPlay()
        } catch {
            print("Failed to initialize AVAudioPlayer: \(error)")
        }
    }

    func playBackgroundMusic() {
        backgroundMusicPlayer?.play()
    }

    func pauseBackgroundMusic() {
        backgroundMusicPlayer?.pause()
    }

    func stopBackgroundMusic() {
        backgroundMusicPlayer?.stop()
    }
}