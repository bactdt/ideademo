import Foundation
import AVFoundation


class AudioRecorder: NSObject, ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    @Published private(set) var audioFileURL: URL? = nil
    @Published var isRecording = false
    @Published var isCloudSyncEnabled = false
    
    private let audioSession = AVAudioSession.sharedInstance()
    private let fileManager = FileManager.default
    
    override init() {
        super.init()
        setupAudioSession()
        do {
            try configureRecorder()
        } catch {
            print("❌ 录音器初始化失败: \(error)")
        }
    }
    
    private func setupAudioSession() {
        do {
            // 配置音频会话
            try audioSession.setCategory(.playAndRecord, mode: .default)
            
            // 请求录音权限
            audioSession.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        print("已获得录音权限")
                        do {
                            try self?.configureRecorder()
                        } catch {
                            print("❌ 录音器初始化失败: \(error)")
                        }
                    } else {
                        print("未获得录音权限")
                    }
                }
            }
            
            try audioSession.setActive(true)
        } catch {
            print("音频会话设置失败: \(error.localizedDescription)")
        }
    }
    
    private func configureRecorder() throws {
        // 确保文档目录存在且可写
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // 检查并创建目录权限
        let resourceValues = try documentsPath.resourceValues(forKeys: [.isWritableKey])
        guard resourceValues.isWritable == true else {
            throw NSError(domain: "AudioRecorderErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "文档目录不可写"])
        }
        
        // 生成唯一的文件名
        let audioFilename = documentsPath.appendingPathComponent("recording_\(Date().timeIntervalSince1970).m4a")
        
        // 详细的录音设置
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        
        // 尝试创建文件
        try "test".write(to: audioFilename, atomically: true, encoding: .utf8)
        try fileManager.removeItem(at: audioFilename)
        
        audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
        audioRecorder?.prepareToRecord()
        audioFileURL = audioFilename
        
        print("✅ 录音器设置成功：\(audioFilename.path)")
    }
    
    func startRecording() {
        // 重置录音状态
        audioRecorder = nil
        audioFileURL = nil
        
        // 确保录音器已正确初始化
        do {
            try configureRecorder()
        } catch {
            print("❌ 录音器初始化失败: \(error)")
            
            // 详细的错误诊断
            let errorDescription = (error as NSError).description
            let errorCode = (error as NSError).code
            let errorDomain = (error as NSError).domain
            
            print("错误详情:")
            print("错误域: \(errorDomain)")
            print("错误码: \(errorCode)")
            print("错误描述: \(errorDescription)")
            
            return
        }
        
        // 再次检查录音器状态
        guard let recorder = audioRecorder, audioFileURL != nil else {
            print("❌ 录音器初始化失败")
            return
        }
        
        do {
            try audioSession.setActive(true)
            recorder.record()
            isRecording = true
            
            print("✅ 开始录音：\(audioFileURL!.path)")
        } catch {
            print("❌ 开始录音失败: \(error.localizedDescription)")
            isRecording = false
            audioFileURL = nil
        }
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        
        do {
            try audioSession.setActive(false)
            
            // 验证录音文件
            guard let url = audioFileURL else {
                print("错误：录音文件URL为空")
                return
            }
            
            guard fileManager.fileExists(atPath: url.path) else {
                print("错误：录音文件不存在")
                return
            }
            
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            
            print("停止录音：\(url.path)")
            print("录音文件大小：\(fileSize) 字节")
            
            // 额外的文件验证
            if fileSize == 0 {
                print("警告：录音文件大小为0")
            }
            
            // 打印文件详细信息
            let audioAsset = AVAsset(url: url)
            let tracks = audioAsset.tracks
            print("总轨道数: \(tracks.count)")
            for track in tracks {
                print("轨道媒体类型: \(track.mediaType.rawValue)")
            }
            
            // 保存录音文件
            saveAudioRecording()
            
        } catch {
            print("录音停止后处理失败: \(error.localizedDescription)")
        }
    }
    
    func deleteRecordingFile() {
        guard let url = audioFileURL else { return }
        
        do {
            try fileManager.removeItem(at: url)
            print("删除录音文件：\(url.path)")
            audioFileURL = nil
        } catch {
            print("删除录音文件失败: \(error.localizedDescription)")
        }
    }
    
    func cleanupOldRecordings(olderThan days: Int = 1) {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey])
            
            let now = Date()
            let oldRecordings = fileURLs.filter { url in
                guard url.pathExtension == "m4a",
                      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                      let creationDate = attributes[.creationDate] as? Date else {
                    return false
                }
                
                return now.timeIntervalSince(creationDate) > Double(days * 24 * 60 * 60)
            }
            
            for url in oldRecordings {
                try fileManager.removeItem(at: url)
                print("删除过期录音文件：\(url.path)")
            }
            
            // 额外清理当前录音文件
            if let currentAudioFileURL = audioFileURL {
                try? fileManager.removeItem(at: currentAudioFileURL)
                audioFileURL = nil
            }
        } catch {
            print("清理录音文件失败: \(error.localizedDescription)")
        }
    }
    
    func syncAudioToiCloud() {
        // 已禁用 iCloud 同步
    }
    
    func saveAudioRecording() {
        guard let url = audioFileURL else {
            print("无法保存：录音文件URL为空")
            return
        }
        
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            // 生成唯一的文件名
            let timestamp = Date().timeIntervalSince1970
            let uniqueFilename = "recording_\(timestamp).m4a"
            let destinationURL = documentsPath.appendingPathComponent(uniqueFilename)
            
            // 如果文件已存在，先删除
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            
            // 复制文件到文档目录
            try fileManager.copyItem(at: url, to: destinationURL)
            
            print("音频文件成功保存：\(destinationURL.path)")
        } catch {
            print("音频本地备份失败: \(error.localizedDescription)")
        }
    }
}
