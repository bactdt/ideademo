import Foundation
import Speech
import AVFoundation

enum TranscriptionError: Error {
    case authorizationDenied
    case fileNotFound
    case transcriptionFailed
}

enum SpeechRecognitionError: Error {
    case authorizationDenied
    case recordingFailed(Error?)
    case recognitionFailed(Error?)
    case serviceUnavailable
    
    var localizedDescription: String {
        switch self {
        case .authorizationDenied:
            return "语音识别权限被拒绝"
        case .recordingFailed(let error):
            return "录音失败: \(error?.localizedDescription ?? "未知错误")"
        case .recognitionFailed(let error):
            return "语音识别失败: \(error?.localizedDescription ?? "未知错误")"
        case .serviceUnavailable:
            return "语音识别服务不可用"
        }
    }
}

class TranscriptionManager: NSObject, ObservableObject {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    
    override init() {
        super.init()
        requestAuthorization()
    }
    
    private func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                self?.authorizationStatus = authStatus
                switch authStatus {
                case .authorized:
                    print("语音识别已授权")
                case .denied:
                    print("用户拒绝了语音识别权限")
                case .restricted:
                    print("语音识别在此设备上受限")
                case .notDetermined:
                    print("语音识别未授权")
                @unknown default:
                    print("未知的授权状态")
                }
            }
        }
    }
    
    func transcribe(url: URL, completion: @escaping (String?) -> Void) {
        // 检查授权状态
        guard authorizationStatus == .authorized else {
            print("转写错误: 未获得语音识别授权")
            completion(nil)
            return
        }
        
        // 检查文件是否存在且可读
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("转写错误: 音频文件不存在 \(url.path)")
            completion(nil)
            return
        }
        
        // 检查文件大小
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            
            guard fileSize > 0 else {
                print("转写错误: 音频文件大小为0")
                completion(nil)
                return
            }
        } catch {
            print("转写错误: 无法获取文件属性 \(error)")
            completion(nil)
            return
        }
        
        // 使用 AVAssetReader 检查音频轨道
        let asset = AVAsset(url: url)
        let audioTracks = asset.tracks(withMediaType: .audio)
        
        guard !audioTracks.isEmpty else {
            print("转写错误: 音频文件没有音频轨道")
            
            // 额外诊断
            let tracks = asset.tracks
            print("总轨道数: \(tracks.count)")
            for track in tracks {
                print("轨道媒体类型: \(track.mediaType.rawValue)")
            }
            
            completion(nil)
            return
        }
        
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        
        speechRecognizer?.recognitionTask(with: request) { result, error in
            if let error = error as? NSError {
                print("转写错误: \(error.localizedDescription)")
                print("错误码: \(error.code)")
                print("域: \(error.domain)")
                
                // 处理特定错误码
                switch error.code {
                case -1685348671: // 可能是音频格式不兼容
                    print("音频格式错误或不兼容")
                case AVError.fileFormatNotRecognized.rawValue:
                    print("音频文件格式无法识别")
                default:
                    print("未知错误")
                }
                
                completion(nil)
                return
            }
            
            guard let result = result else {
                print("转写错误: 未知错误，无法获取转写结果")
                completion(nil)
                return
            }
            
            if result.isFinal {
                let transcribedText = result.bestTranscription.formattedString
                if transcribedText.isEmpty {
                    print("转写警告: 转写结果为空")
                }
                completion(transcribedText)
            }
        }
    }
    
    func transcribeAudio(audioURL: URL, completion: @escaping (Result<String, SpeechRecognitionError>) -> Void) {
        // 检查语音识别权限
        SFSpeechRecognizer.requestAuthorization { status in
            switch status {
            case .authorized:
                self.performSpeechRecognition(audioURL: audioURL, completion: completion)
            case .denied, .restricted:
                completion(.failure(.authorizationDenied))
            case .notDetermined:
                completion(.failure(.authorizationDenied))
            @unknown default:
                completion(.failure(.authorizationDenied))
            }
        }
    }
    
    private func performSpeechRecognition(audioURL: URL, completion: @escaping (Result<String, SpeechRecognitionError>) -> Void) {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            completion(.failure(.recordingFailed(nil)))
            return
        }
        
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) else {
            completion(.failure(.serviceUnavailable))
            return
        }
        
        guard recognizer.isAvailable else {
            completion(.failure(.serviceUnavailable))
            return
        }
        
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        
        recognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                if let error = error {
                    // 安全地获取错误域和错误码
                    let nsError = error as NSError
                    
                    // 详细记录错误信息
                    print("❌ 语音识别错误: \(error)")
                    print("❌ 错误域: \(nsError.domain)")
                    print("❌ 错误码: \(nsError.code)")
                    
                    // 处理特定的错误情况
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101 {
                        completion(.failure(.serviceUnavailable))
                    } else {
                        completion(.failure(.recognitionFailed(error)))
                    }
                    return
                }
                
                guard let result = result else {
                    completion(.failure(.recognitionFailed(nil)))
                    return
                }
                
                if result.isFinal {
                    let transcription = result.bestTranscription.formattedString
                    completion(.success(transcription))
                }
            }
        }
    }
}
