import Foundation

class AISettings: ObservableObject {
    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "AIApiKey")
        }
    }
    
    @Published var endpoint: String {
        didSet {
            UserDefaults.standard.set(endpoint, forKey: "AIEndpoint")
        }
    }
    
    @Published var model: String {
        didSet {
            UserDefaults.standard.set(model, forKey: "AIModel")
        }
    }
    
    @Published var systemPrompt: String {
        didSet {
            UserDefaults.standard.set(systemPrompt, forKey: "AISystemPrompt")
        }
    }
    
    init() {
        self.apiKey = UserDefaults.standard.string(forKey: "AIApiKey") ?? ""
        self.endpoint = UserDefaults.standard.string(forKey: "AIEndpoint") ?? "https://api.openai.com/v1/chat/completions"
        self.model = UserDefaults.standard.string(forKey: "AIModel") ?? "gpt-3.5-turbo"
        self.systemPrompt = UserDefaults.standard.string(forKey: "AISystemPrompt") ?? "你是一个标签分类助手。你的任务是分析用户输入的文本内容并返回相关标签。要求：1. 只返回JSON格式的标签数组，不要有任何其他文字说明；2. 如果找不到合适的标签，返回空数组 []；3. 标签应该简短且有意义。示例输入：'今天去打麻将'，你应该直接返回：['娱乐','社交']"
    }
}
