import Foundation

struct Todo: Codable, Equatable {
    var id: String?
    var content: String
    var status: String

    enum CodingKeys: String, CodingKey { case id, content, status }
}

struct TaskChange: Decodable, Equatable {
    var id: String?
    var subject: String?
    var status: String?
}

extension [Todo] {
    var completed: Int { filter { $0.status == "completed" }.count }
    var inProgress: Todo? { first { $0.status == "in_progress" } }

    mutating func apply(todos: [Todo]?, task: TaskChange?) {
        if let todos { self = todos }
        guard let task, let id = task.id else { return }
        if let i = firstIndex(where: { $0.id == id }) {
            if task.status == "deleted" { remove(at: i); return }
            if let status = task.status { self[i].status = status }
            if let subject = task.subject { self[i].content = subject }
        } else if task.status != "deleted" {
            append(Todo(id: id, content: task.subject ?? "Task \(id)", status: task.status ?? "pending"))
        }
    }
}
