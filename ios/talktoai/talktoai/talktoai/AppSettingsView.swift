import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var aiSettings: AISettings
    @ObservedObject var audioRecorder: AudioRecorder
    @ObservedObject var transcriptionRecordStore: TranscriptionRecordStore
    
    @AppStorage("selectedLanguage") private var selectedLanguage = "zh-CN"
    
    let languages = [
        "zh-CN": "简体中文",
        "en-US": "English",
        "ja-JP": "日本语"
    ]
    
    @State private var showingDeleteConfirmation = false
    @State private var showingAudioDeleteConfirmation = false
    
    init(aiSettings: AISettings, audioRecorder: AudioRecorder, transcriptionRecordStore: TranscriptionRecordStore) {
        self.aiSettings = aiSettings
        self.audioRecorder = audioRecorder
        self.transcriptionRecordStore = transcriptionRecordStore
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    NavigationLink(destination: AISettingsView(settings: aiSettings)) {
                        aiConfigView
                    }
                } header: {
                    Text("AI设置")
                }
                
                Section {
                    audioCacheCleanButton
                    textRecordCleanButton
                } header: {
                    Text("缓存管理")
                }
                
                Section {
                    languagePicker
                } header: {
                    Text("语言设置")
                }
            }
            .navigationTitle("应用设置")
        }
    }
    
    private var aiConfigView: some View {
        HStack {
            Text("AI配置")
            Spacer()
            Image(systemName: "gear")
        }
    }
    
    private var audioCacheCleanButton: some View {
        Button(action: {
            showingAudioDeleteConfirmation = true
        }) {
            HStack {
                Image(systemName: "trash")
                Text("清除所有音频缓存")
            }
            .foregroundColor(.red)
        }
        .alert(isPresented: $showingAudioDeleteConfirmation) {
            Alert(
                title: Text("确认清除"),
                message: Text("是否确定要删除所有音频缓存？此操作不可撤销。"),
                primaryButton: .destructive(Text("删除")) {
                    audioRecorder.cleanupOldRecordings(olderThan: 0)
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    private var textRecordCleanButton: some View {
        Button(action: {
            showingDeleteConfirmation = true
        }) {
            HStack {
                Image(systemName: "trash")
                Text("清除所有文字记录")
            }
            .foregroundColor(.red)
        }
        .alert(isPresented: $showingDeleteConfirmation) {
            Alert(
                title: Text("确认清除"),
                message: Text("是否确定要删除所有文字记录？此操作不可撤销。"),
                primaryButton: .destructive(Text("删除")) {
                    transcriptionRecordStore.clearAllRecords()
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    private var languagePicker: some View {
        Picker("识别语言", selection: $selectedLanguage) {
            ForEach(Array(languages.keys), id: \.self) { languageCode in
                Text(languages[languageCode] ?? languageCode).tag(languageCode)
            }
        }
    }
}
