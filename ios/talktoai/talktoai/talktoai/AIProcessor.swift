import Foundation
import SwiftUI

enum AIProcessingError: Error {
    case invalidEndpoint
    case serializationError
    case networkError(Error)
    case noData
    case invalidResponse
    case parsingError
    case missingAPIKey
}

struct AIProcessingResult {
    let processedText: String
    let keywords: [String]
    let timeKeywords: [String]
    let spaceKeywords: [String]
    let tags: [String]
}

class AIProcessor: ObservableObject {
    var settings: AISettings
    var transcriptionRecordStore: TranscriptionRecordStore // Add this line
    
    // 预定义的时间关键词
    private let predefinedTimeKeywords = [
        "今天", "明天", "后天", "昨天", 
        "上午", "下午", "晚上", "早上", "中午", 
        "凌晨", "傍晚", "周一", "周二", "周三", "周四", "周五", "周六", "周日"
    ]
    
    // 预定义的空间关键词
    private let predefinedSpaceKeywords = [
        "家里", "办公室", "学校", "公司", "教室",
        "户外", "室内", "城市", "乡村", 
        "山上", "海边", "河边", "湖边", "公园", "街道", "广场"
    ]
    
    // 预定义标签列表
    private let predefinedTags = [
        "计划", "活动", "娱乐", "社交", "个人", 
        "工作", "学习", "休闲", "运动", "艺术",
        "音乐", "舞蹈", "电影", "阅读", "旅行"
    ]
    
    init(settings: AISettings = AISettings(), transcriptionRecordStore: TranscriptionRecordStore = TranscriptionRecordStore()) {
        self.settings = settings
        self.transcriptionRecordStore = transcriptionRecordStore
    }
    
    func updateSettings(_ newSettings: AISettings) {
        self.settings = newSettings
    }
    
    func processText(_ text: String, completion: @escaping (Result<AIProcessingResult, AIProcessingError>) -> Void) {
        guard !settings.apiKey.isEmpty else {
            completion(.failure(.missingAPIKey))
            return
        }
        
        // 预处理文本
        let processedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 提取关键词
        let keywords = extractKeywords(from: processedText)
        let timeKeywords = keywords.filter { predefinedTimeKeywords.contains($0) }
        let spaceKeywords = keywords.filter { predefinedSpaceKeywords.contains($0) }
        
        // 生成标签
        var tags = generateTags(from: processedText)
        
        // 如果没有生成标签，尝试从关键词中提取
        if tags.isEmpty {
            tags = keywords.filter { predefinedTags.contains($0) }
        }
        
        // 确保标签不为空且不包含 "null"
        tags = tags.filter { !$0.isEmpty && $0 != "null" }
        
        // 创建记录
        let record = TranscriptionRecord(
            originalText: text,
            processedText: processedText,
            keywords: keywords,
            timeKeywords: timeKeywords,
            spaceKeywords: spaceKeywords,
            tags: tags
        )
        
        // 确保标签被传递
        DispatchQueue.main.async {
            self.transcriptionRecordStore.addRecord(record)
        }
        
        // 创建 AIProcessingResult 时也传递标签
        let result = AIProcessingResult(
            processedText: processedText,
            keywords: keywords,
            timeKeywords: timeKeywords,
            spaceKeywords: spaceKeywords,
            tags: tags
        )
        
        completion(.success(result))
    }
    
    // 辅助方法：从文本中提取关键词
    func extractKeywords(from text: String) -> [String] {
        let commonKeywords = ["拜年", "春节", "新年", "祝福", "礼物", "红包"]
        return commonKeywords.filter { text.contains($0) }
    }
    
    // 辅助方法：生成描述性标签
    func generateTags(from text: String) -> [String] {
        // 活动和标签映射
        let activityTagMap: [String: [String]] = [
            "唱歌": ["娱乐", "音乐", "计划"],
            "跳舞": ["运动", "娱乐", "计划"],
            "看电影": ["娱乐", "文化", "计划"],
            "吃饭": ["社交", "生活", "计划"],
            "运动": ["健康", "运动", "计划"],
            "学习": ["成长", "学习", "个人"],
            "工作": ["职业", "工作", "计划"]
        ]
        
        // 首先尝试从预定义标签中匹配
        let matchedTags = predefinedTags.filter { tag in
            text.contains(tag)
        }
        
        // 如果有匹配的标签，直接返回
        if !matchedTags.isEmpty {
            return matchedTags
        }
        
        // 尝试从活动映射中提取标签
        for (activity, tags) in activityTagMap {
            if text.contains(activity) {
                return tags
            }
        }
        
        // 尝试从关键词中提取标签
        let keywords = extractKeywords(from: text)
        let keywordTags = keywords.filter { predefinedTags.contains($0) }
        
        // 如果有关键词标签，返回关键词标签
        if !keywordTags.isEmpty {
            return keywordTags
        }
        
        // 如果还是没有标签，返回通用标签
        return ["个人", "计划"]
    }
    
    func getSettings() -> AISettings {
        return settings
    }
}
