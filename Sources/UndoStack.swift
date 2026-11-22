import Foundation

/// Undo / Redo 用の履歴スタック
struct UndoStack<T> {
    private(set) var past: [T] = []
    private(set) var future: [T] = []
    var limit = 50

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    mutating func record(_ state: T) {
        past.append(state)
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }

    mutating func undo(current: T) -> T? {
        guard let prev = past.popLast() else { return nil }
        future.append(current)
        return prev
    }

    mutating func redo(current: T) -> T? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }
}
