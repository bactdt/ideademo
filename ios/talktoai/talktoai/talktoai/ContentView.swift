import SwiftUI
import AVFoundation

// 录音动画组件
struct RecordingAnimationView: View {
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.5
    
    var body: some View {
        ZStack {
            // 外圈动画
            Circle()
                .stroke(
                    LinearGradient(
                        gradient: Gradient(colors: [.red.opacity(0.5), .red.opacity(0.2)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 4
                )
                .scaleEffect(scale)
                .opacity(opacity)
                .animation(
                    Animation
                        .easeInOut(duration: 1)
                        .repeatForever(autoreverses: true),
                    value: scale
                )
            
            // 内圈动画
            Circle()
                .stroke(
                    LinearGradient(
                        gradient: Gradient(colors: [.red.opacity(0.7), .red.opacity(0.4)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 4
                )
                .scaleEffect(scale * 0.7)
                .opacity(opacity)
                .animation(
                    Animation
                        .easeInOut(duration: 1)
                        .repeatForever(autoreverses: true)
                        .delay(0.2),
                    value: scale
                )
        }
        .frame(width: 44, height: 44)
        .onAppear {
            scale = 1.2
            opacity = 0.2
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let processedText: String
    let tags: [String]
    let isProcessed: Bool
    let timestamp: Date
}

struct ContentView: View {
    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var aiSettings = AISettings()
    @StateObject private var aiProcessor = AIProcessor()
    @StateObject private var transcriptionRecordStore = TranscriptionRecordStore()
    
    @State private var isRecording = false
    @State private var showingProcessedText = false
    @State private var originalText = ""
    @State private var processedText = ""
    @State private var keywords: [String] = []
    @State private var tags: [String] = []
    @State private var showingSettings = false
    @State private var inputText = ""
    @State private var chatMessages: [ChatMessage] = []
    @State private var scrollProxy: ScrollViewProxy? = nil
    
    var body: some View {
        TabView {
            NavigationView {
                VStack(spacing: 0) {
                    // 聊天记录区域
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(chatMessages) { message in
                                    if !message.isProcessed {
                                        // 用户输入（右侧）
                                        HStack {
                                            Spacer()
                                            Text(message.text)
                                                .padding(12)
                                                .background(Color.blue)
                                                .foregroundColor(.white)
                                                .cornerRadius(16)
                                                .padding(.horizontal)
                                        }
                                        .id(message.id)
                                    } else {
                                        // AI 响应（左侧）
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 8) {
                                                Text(message.processedText)
                                                    .padding(12)
                                                    .background(Color.gray.opacity(0.1))
                                                    .cornerRadius(16)
                                                
                                                if !message.tags.isEmpty {
                                                    HStack {
                                                        ForEach(message.tags, id: \.self) { tag in
                                                            Text(tag)
                                                                .font(.caption)
                                                                .padding(.horizontal, 8)
                                                                .padding(.vertical, 4)
                                                                .background(Color.blue.opacity(0.2))
                                                                .cornerRadius(12)
                                                        }
                                                    }
                                                }
                                            }
                                            .padding(.horizontal)
                                            Spacer()
                                        }
                                        .id(message.id)
                                    }
                                }
                            }
                            .padding(.vertical)
                        }
                        .onAppear {
                            scrollProxy = proxy
                        }
                    }
                    
                    // 底部输入区域
                    HStack(spacing: 12) {
                        ZStack {
                            Button(action: {
                                handleRecordingAction()
                            }) {
                                Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                    .resizable()
                                    .frame(width: 32, height: 32)
                                    .foregroundColor(isRecording ? .red : .blue)
                            }
                            
                            if isRecording {
                                RecordingAnimationView()
                                    .transition(.opacity)
                            }
                        }
                        
                        TextField("输入文字...", text: $inputText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .disabled(isRecording)
                        
                        if !inputText.isEmpty {
                            Button(action: {
                                addUserMessage(inputText)
                                processAudioTranscription(inputText)
                                inputText = ""
                            }) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .resizable()
                                    .frame(width: 32, height: 32)
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.systemBackground))
                    .overlay(
                        Rectangle()
                            .frame(height: 1)
                            .foregroundColor(Color.gray.opacity(0.2)),
                        alignment: .top
                    )
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            showingSettings = true
                        }) {
                            Image(systemName: "gear")
                        }
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    AppSettingsView(
                        aiSettings: aiSettings,
                        audioRecorder: audioRecorder,
                        transcriptionRecordStore: transcriptionRecordStore
                    )
                }
            }
            .tabItem {
                Image(systemName: "mic")
                Text("录音")
            }
            
            HistoryView(transcriptionRecordStore: transcriptionRecordStore)
                .tabItem {
                    Image(systemName: "list.bullet")
                    Text("历史")
                }
        }
    }
    
    private func addUserMessage(_ text: String) {
        let message = ChatMessage(text: text, processedText: "", tags: [], isProcessed: false, timestamp: Date())
        chatMessages.append(message)
        scrollToBottom()
    }
    
    private func addProcessedMessage(_ text: String, processedText: String, tags: [String]) {
        let message = ChatMessage(text: text, processedText: processedText, tags: tags, isProcessed: true, timestamp: Date())
        chatMessages.append(message)
        scrollToBottom()
    }
    
    private func scrollToBottom() {
        if let lastMessage = chatMessages.last {
            withAnimation {
                scrollProxy?.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
    
    private func handleRecordingAction() {
        if audioRecorder.isRecording {
            audioRecorder.stopRecording()
            isRecording = false
            
            // 异步处理录音文件
            DispatchQueue.global(qos: .userInitiated).async {
                guard let audioURL = audioRecorder.audioFileURL else { return }
                
                transcriptionManager.transcribeAudio(audioURL: audioURL) { result in
                    switch result {
                    case .success(let transcription):
                        DispatchQueue.main.async {
                            originalText = transcription
                            addUserMessage(transcription)
                            processAudioTranscription(transcription)
                        }
                    case .failure(let error):
                        print("语音识别错误: \(error.localizedDescription)")
                        // 错误处理
                    }
                }
            }
        } else {
            audioRecorder.startRecording()
            isRecording = true
            showingProcessedText = false
        }
    }
    
    private func processAudioTranscription(_ transcription: String) {
        // 更新 AIProcessor 的设置
        aiProcessor.updateSettings(aiSettings)
        
        // 异步处理文本
        DispatchQueue.global(qos: .userInitiated).async {
            aiProcessor.processText(transcription) { result in
                switch result {
                case .success(let processed):
                    DispatchQueue.main.async {
                        processedText = processed.processedText
                        keywords = processed.keywords
                        tags = processed.tags
                        
                        addProcessedMessage(transcription, processedText: processed.processedText, tags: processed.tags)
                        showingProcessedText = true
                    }
                case .failure(let error):
                    print("文本处理错误: \(error)")
                }
            }
        }
    }
    
    func deleteRecord(at offsets: IndexSet) {
        transcriptionRecordStore.removeRecord(at: offsets)
    }
}

struct HistoryView: View {
    @ObservedObject var transcriptionRecordStore: TranscriptionRecordStore
    @State private var showingDeleteConfirmation = false
    @State private var selectedTag: String? = nil
    
    var filteredRecords: [TranscriptionRecord] {
        // 先过滤掉标签记录
        let nonTagRecords = transcriptionRecordStore.records.filter { record in
            !(record.processedText == record.originalText && 
              record.keywords == [record.processedText] && 
              record.timeKeywords.isEmpty && 
              record.spaceKeywords.isEmpty)
        }
        
        guard let selectedTag = selectedTag else {
            // 如果没有选择标签，直接返回过滤后的记录
            return nonTagRecords
        }
        
        // 如果选择了标签，返回同时满足标签条件的记录
        return nonTagRecords.filter { record in
            record.timeKeywords.contains(selectedTag) || 
            record.spaceKeywords.contains(selectedTag)
        }
    }
    
    var allTags: [String] {
        // 获取所有非 null 的时间和空间关键词
        let timeKeywords = transcriptionRecordStore.getAllUniqueTimeKeywords()
            .filter { $0 != "null" }
        let spaceKeywords = transcriptionRecordStore.getAllUniqueSpaceKeywords()
            .filter { $0 != "null" }
        
        // 合并并排序
        return (timeKeywords + spaceKeywords).sorted()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    TagButton(
                        text: "全部", 
                        isSelected: selectedTag == nil
                    ) {
                        selectedTag = nil
                    }
                    
                    ForEach(allTags, id: \.self) { tag in
                        TagButton(
                            text: tag, 
                            isSelected: selectedTag == tag
                        ) {
                            selectedTag = tag
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 12)
            .background(Color(UIColor.systemBackground))
            
            List {
                ForEach(filteredRecords) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.processedText)
                            .font(.body)
                            .contextMenu {
                                Button(action: {
                                    UIPasteboard.general.string = record.processedText
                                }) {
                                    Text("复制")
                                    Image(systemName: "doc.on.doc")
                                }
                            }
                        
                        HStack {
                            // 显示时间关键词
                            ForEach(record.timeKeywords.filter { $0 != "null" }, id: \.self) { keyword in
                                Text(keyword)
                                    .font(.caption)
                                    .padding(4)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(8)
                            }
                            
                            Spacer()
                            
                            // 显示空间关键词
                            ForEach(record.spaceKeywords.filter { $0 != "null" }, id: \.self) { keyword in
                                Text(keyword)
                                    .font(.caption)
                                    .padding(4)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(8)
                            }
                        }
                        
                        // 添加标签在右下角
                        HStack {
                            Spacer()
                            ForEach(record.tags.filter { $0 != "null" }, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Color.blue)
                                    .cornerRadius(8)
                            }
                        }
                        .onAppear {
                            // 移除标签详情的打印
                        }
                    }
                }
                .onDelete(perform: deleteRecord)
            }
        }
    }
    
    func deleteRecord(at offsets: IndexSet) {
        transcriptionRecordStore.removeRecord(at: offsets)
    }
}

struct TagButton: View {
    let text: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSelected ? Color.blue : Color.gray.opacity(0.1))
                )
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        }
    }
}

