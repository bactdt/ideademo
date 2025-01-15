import SwiftUI

struct AISettingsView: View {
    @ObservedObject var settings: AISettings
    @Environment(\.dismiss) private var dismiss
    @State private var isTestingAPI = false
    @State private var testResult: String?
    @State private var showingTestResult = false
    @State private var selectedEndpointType = "custom"
    @State private var selectedModelType = "preset"
    @State private var customModel: String = ""
    @State private var isEditingPrompt = false
    
    let availableModels = [
        "gpt-3.5-turbo",
        "gpt-4",
        "gpt-4-turbo-preview",
        "claude-3-opus-20240229",
        "claude-3-sonnet-20240229"
    ]
    
    let predefinedEndpoints = [
        "custom": "自定义",
        "openai": "https://api.openai.com/v1/chat/completions",
        "azure": "https://your-resource.openai.azure.com/openai/deployments/your-deployment-name/chat/completions?api-version=2024-02-15-preview",
        "claude": "https://api.anthropic.com/v1/messages"
    ]
    
    let predefinedPrompts = [
        "默认助手": "你是一个有帮助的AI助手。",
        "翻译助手": "你是一个专业的翻译助手，请帮助用户进行准确的翻译。",
        "代码助手": "你是一个专业的编程助手，擅长编写和解释代码。",
        "写作助手": "你是一个专业的写作助手，擅长改进文章结构和表达。",
        "标签助手": "你是一个标签分类助手。你的任务是分析用户输入的文本内容并返回相关标签。要求：1. 只返回JSON格式的标签数组，不要有任何其他文字说明；2. 如果找不到合适的标签，返回空数组 []；3. 标签应该简短且有意义。示例输入：'今天去打麻将'，你应该直接返回：['娱乐','社交']"
    ]
    
    var body: some View {
        Form {
            Section(header: Text("API设置")) {
                SecureField("API密钥", text: $settings.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                
                Picker("API类型", selection: $selectedEndpointType) {
                    ForEach(Array(predefinedEndpoints.keys), id: \.self) { key in
                        Text(predefinedEndpoints[key] ?? "")
                            .tag(key)
                    }
                }
                .onChange(of: selectedEndpointType) { newValue in
                    if newValue != "custom" {
                        settings.endpoint = predefinedEndpoints[newValue] ?? ""
                    }
                }
                
                if selectedEndpointType == "custom" {
                    TextField("自定义API端点", text: $settings.endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Text(settings.endpoint)
                        .foregroundColor(.gray)
                }
                
                Picker("模型选择", selection: $selectedModelType) {
                    Text("预设模型").tag("preset")
                    Text("自定义模型").tag("custom")
                }
                
                if selectedModelType == "preset" {
                    Picker("选择模型", selection: $settings.model) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                } else {
                    TextField("输入模型名称", text: $customModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: customModel) { newValue in
                            settings.model = newValue
                        }
                }
            }
            
            Section(header: Text("系统提示词")) {
                Button(action: {
                    isEditingPrompt = true
                }) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("当前提示词")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Text(settings.systemPrompt)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.gray)
                    }
                }
            }
            
            Section {
                Button(action: testAPI) {
                    HStack {
                        Text("测试API连接")
                        if isTestingAPI {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(settings.apiKey.isEmpty || isTestingAPI)
            }
            
            Section(header: Text("提示")) {
                Text("支持OpenAI格式的API，如：")
                VStack(alignment: .leading, spacing: 8) {
                    Text("• OpenAI (api.openai.com)")
                    Text("• Azure OpenAI")
                    Text("• Claude (claude.ai)")
                    Text("• 其他兼容格式的API")
                }
                Text("请确保填写正确的API密钥和端点地址")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .navigationTitle("AI设置")
        .navigationBarItems(trailing: Button("完成") {
            dismiss()
        })
        .alert("API测试结果", isPresented: $showingTestResult) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(testResult ?? "")
        }
        .sheet(isPresented: $isEditingPrompt) {
            NavigationView {
                Form {
                    Section(header: Text("预设提示词")) {
                        ForEach(Array(predefinedPrompts.keys), id: \.self) { key in
                            Button(action: {
                                settings.systemPrompt = predefinedPrompts[key] ?? ""
                                isEditingPrompt = false
                            }) {
                                VStack(alignment: .leading) {
                                    Text(key)
                                        .foregroundColor(.primary)
                                    Text(predefinedPrompts[key] ?? "")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    
                    Section(header: Text("自定义提示词")) {
                        TextEditor(text: $settings.systemPrompt)
                            .frame(minHeight: 100)
                    }
                }
                .navigationTitle("系统提示词")
                .navigationBarItems(trailing: Button("完成") {
                    isEditingPrompt = false
                })
            }
        }
        .onAppear {
            customModel = settings.model
        }
    }
    
    private func testAPI() {
        isTestingAPI = true
        // 这里添加实际的API测试逻辑
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            testResult = "API连接成功！"
            isTestingAPI = false
            showingTestResult = true
        }
    }
}

#Preview {
    NavigationView {
        AISettingsView(settings: AISettings())
    }
}
