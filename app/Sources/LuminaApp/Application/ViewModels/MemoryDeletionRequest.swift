import Foundation

enum MemoryDeletionRequest: Identifiable {
    case one(id: UUID, title: String)
    case all(count: Int)

    var id: String {
        switch self {
        case .one(let id, _):
            return id.uuidString
        case .all:
            return "all"
        }
    }

    var title: String {
        switch self {
        case .one:
            return "删除这条记忆？"
        case .all:
            return "删除全部记忆？"
        }
    }

    var message: String {
        switch self {
        case .one(_, let title):
            return "“\(title)” 将从本机记忆库中删除。这个操作无法自动恢复。"
        case .all(let count):
            return "将从本机记忆库中删除全部 \(count) 条记忆。这个操作无法自动恢复。"
        }
    }
}
