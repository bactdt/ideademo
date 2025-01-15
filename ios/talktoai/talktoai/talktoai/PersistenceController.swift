import CoreData
import Foundation

struct PersistenceController {
    static let shared = PersistenceController()
    
    let container: NSPersistentContainer
    
    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "TranscriptionModel")
        
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        
        container.loadPersistentStores { (storeDescription, error) in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
    
    // 保存转录记录
    func saveTranscriptionRecord(
        originalText: String,
        processedText: String,
        keywords: [String],
        timeKeywords: [String],
        spaceKeywords: [String],
        tags: [String]
    ) {
        let context = container.viewContext
        
        let record = TranscriptionRecordEntity(context: context)
        record.id = UUID()
        record.originalText = originalText
        record.processedText = processedText
        record.keywords = keywords as NSObject
        record.timeKeywords = timeKeywords as NSObject
        record.spaceKeywords = spaceKeywords as NSObject
        record.tags = tags as NSObject
        record.timestamp = Date()
        
        do {
            try context.save()
            print("记录已成功保存到数据库")
        } catch {
            let nsError = error as NSError
            print("保存记录失败: \(nsError), \(nsError.userInfo)")
        }
    }
    
    // 获取所有转录记录
    func fetchTranscriptionRecords() -> [TranscriptionRecordEntity] {
        let context = container.viewContext
        let request: NSFetchRequest<TranscriptionRecordEntity> = TranscriptionRecordEntity.fetchRequest()
        
        // 按时间戳降序排序
        let sortDescriptor = NSSortDescriptor(key: "timestamp", ascending: false)
        request.sortDescriptors = [sortDescriptor]
        
        do {
            return try context.fetch(request)
        } catch {
            print("获取记录失败: \(error)")
            return []
        }
    }
    
    // 删除特定记录
    func deleteTranscriptionRecord(_ record: TranscriptionRecordEntity) {
        let context = container.viewContext
        context.delete(record)
        
        do {
            try context.save()
            print("记录已成功删除")
        } catch {
            let nsError = error as NSError
            print("删除记录失败: \(nsError), \(nsError.userInfo)")
        }
    }
    
    // 清空所有记录
    func clearAllRecords() {
        let context = container.viewContext
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = TranscriptionRecordEntity.fetchRequest()
        let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        do {
            try context.execute(batchDeleteRequest)
            try context.save()
            print("所有记录已清空")
        } catch {
            let nsError = error as NSError
            print("清空记录失败: \(nsError), \(nsError.userInfo)")
        }
    }
}
