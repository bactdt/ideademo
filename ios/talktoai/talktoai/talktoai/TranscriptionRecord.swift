import Foundation
import CloudKit
import CoreData

struct TranscriptionRecord: Identifiable, Codable {
    let id: UUID
    let originalText: String
    let processedText: String
    let keywords: [String]
    let timeKeywords: [String]
    let spaceKeywords: [String]
    let tags: [String]
    let timestamp: Date
    
    // 预定义的时间关键词
    private static let predefinedTimeKeywords = [
        "今天", "明天", "后天", "昨天", 
        "上午", "下午", "晚上", "早上", "中午", 
        "凌晨", "傍晇", "周一", "周二", "周三", "周四", "周五", "周六", "周日"
    ]
    
    // 预定义的空间关键词
    private static let predefinedSpaceKeywords = [
        "家里", "办公室", "学校", "公司", "教室",
        "户外", "室内", "城市", "乡村", 
        "山上", "海边", "河边", "湖边", "公园", "街道", "广场"
    ]
    
    init(originalText: String, processedText: String, keywords: [String], timeKeywords: [String] = [], spaceKeywords: [String] = [], tags: [String] = []) {
        self.id = UUID()
        self.originalText = originalText
        self.processedText = processedText
        self.keywords = keywords
        
        // 从关键词中提取时间和空间关键词
        let extractedTimeKeywords = keywords.filter { Self.isTimeKeyword($0) }
        let extractedSpaceKeywords = keywords.filter { Self.isSpaceKeyword($0) }
        
        self.timeKeywords = !timeKeywords.isEmpty ? timeKeywords : extractedTimeKeywords
        self.spaceKeywords = !spaceKeywords.isEmpty ? spaceKeywords : extractedSpaceKeywords
        
        // 确保标签不为空
        self.tags = tags.isEmpty ? [] : tags
        
        self.timestamp = Date()
    }
    
    // 时间关键词判断
    private static func isTimeKeyword(_ keyword: String) -> Bool {
        return predefinedTimeKeywords.contains(keyword)
    }
    
    // 空间关键词判断
    private static func isSpaceKeyword(_ keyword: String) -> Bool {
        return predefinedSpaceKeywords.contains(keyword)
    }
    
    // 自定义编码和解码方法，确保标签能够正确处理
    enum CodingKeys: String, CodingKey {
        case id, originalText, processedText, keywords, timeKeywords, spaceKeywords, tags, timestamp
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        originalText = try container.decode(String.self, forKey: .originalText)
        processedText = try container.decode(String.self, forKey: .processedText)
        keywords = try container.decode([String].self, forKey: .keywords)
        timeKeywords = try container.decode([String].self, forKey: .timeKeywords)
        spaceKeywords = try container.decode([String].self, forKey: .spaceKeywords)
        
        // 尝试解码标签，如果失败则使用空数组
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }
}

class TranscriptionRecordStore: ObservableObject {
    @Published var records: [TranscriptionRecord] = []
    private let persistenceController = PersistenceController.shared
    
    init() {
        loadRecords()
    }
    
    func loadRecords() {
        let coreDataRecords = persistenceController.fetchTranscriptionRecords()
        
        records = coreDataRecords.map { entity in
            TranscriptionRecord(
                originalText: entity.originalText ?? "",
                processedText: entity.processedText ?? "",
                keywords: entity.keywords as? [String] ?? [],
                timeKeywords: entity.timeKeywords as? [String] ?? [],
                spaceKeywords: entity.spaceKeywords as? [String] ?? [],
                tags: entity.tags as? [String] ?? []
            )
        }
        
        print("从数据库加载记录数量: \(records.count)")
    }
    
    func addRecord(_ record: TranscriptionRecord) {
        // 过滤标签
        let filteredRecord = TranscriptionRecord(
            originalText: record.originalText,
            processedText: record.processedText,
            keywords: record.keywords,
            timeKeywords: record.timeKeywords,
            spaceKeywords: record.spaceKeywords,
            tags: record.tags.filter { !$0.isEmpty && $0 != "null" }
        )
        
        // 检查是否已存在相同的记录（检查原始文本和处理后文本）
        let isDuplicate = records.contains { existingRecord in
            existingRecord.originalText == filteredRecord.originalText ||
            existingRecord.processedText == filteredRecord.processedText
        }
        
        if !isDuplicate {
            // 保存到 CoreData
            persistenceController.saveTranscriptionRecord(
                originalText: filteredRecord.originalText,
                processedText: filteredRecord.processedText,
                keywords: filteredRecord.keywords,
                timeKeywords: filteredRecord.timeKeywords,
                spaceKeywords: filteredRecord.spaceKeywords,
                tags: filteredRecord.tags
            )
            
            // 更新本地记录
            records.insert(filteredRecord, at: 0)
        }
    }
    
    func removeRecord(at offsets: IndexSet) {
        offsets.forEach { index in
            let recordToDelete = records[index]
            
            // 从 CoreData 中删除
            let coreDataRecords = persistenceController.fetchTranscriptionRecords()
            if let entityToDelete = coreDataRecords.first(where: { 
                $0.originalText == recordToDelete.originalText && 
                $0.processedText == recordToDelete.processedText 
            }) {
                persistenceController.deleteTranscriptionRecord(entityToDelete)
            }
        }
        
        records.remove(atOffsets: offsets)
    }
    
    func clearAllRecords() {
        persistenceController.clearAllRecords()
        records.removeAll()
        print("已清空所有记录")
    }
    
    // 按时间和空间关键词筛选
    func filterRecords(timeKeyword: String? = nil, spaceKeyword: String? = nil) -> [TranscriptionRecord] {
        return records.filter { record in
            let timeMatch = timeKeyword == nil || record.timeKeywords.contains(timeKeyword!)
            let spaceMatch = spaceKeyword == nil || record.spaceKeywords.contains(spaceKeyword!)
            
            // 同时满足两个关键词（如果都提供）
            return timeMatch && spaceMatch
        }
    }
    
    // 获取所有唯一的时间关键词
    func getAllUniqueTimeKeywords() -> [String] {
        let allTimeKeywords = records.flatMap { $0.timeKeywords }
        return Array(Set(allTimeKeywords)).sorted()
    }
    
    // 获取所有唯一的空间关键词
    func getAllUniqueSpaceKeywords() -> [String] {
        let allSpaceKeywords = records.flatMap { $0.spaceKeywords }
        return Array(Set(allSpaceKeywords)).sorted()
    }
    
    // 根据关键词创建标签记录
    func createTagRecord(keyword: String) -> TranscriptionRecord? {
        // 直接返回 nil，不创建任何记录
        return nil
    }
}
