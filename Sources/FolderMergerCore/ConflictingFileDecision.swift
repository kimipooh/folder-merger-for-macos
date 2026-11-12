import Foundation

/// A scan result, independent of whether the output was eventually published.
public struct ConflictingFileDecision: Sendable {
    public let relativePath: String
    public let selectedInput: URL
    public let rejectedInputs: [URL]
    public let policy: SamePathPolicy
    public let scanCompleted: Bool
    public var selectedModificationTime: FileModificationTime? = nil
    public var rejectedModificationTimes: [FileModificationTime] = []
    public var description: String {
        L("Path: %@ | Selected: %@ | Rejected: %@ | Rule: %@", relativePath, selectedInput.path,
          rejectedInputs.map(\.path).joined(separator: "; "), policy.label)
    }
}

/// Bounded screen state; the journal independently retains every decision.
public struct ConflictingFileDecisions: Sendable {
    public let limit: Int
    public private(set) var count = 0
    public private(set) var items: [ConflictingFileDecision] = []
    public var omitted: Int { count - items.count }
    public init(limit: Int = 1000) { self.limit = max(0, limit) }
    public mutating func append(_ decision: ConflictingFileDecision) {
        count += 1
        if items.count < limit { items.append(decision) }
    }
}
