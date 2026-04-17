import Foundation

public struct AXElementSearchCriteria: Sendable {
    public var role: String?
    public var title: String?
    public var titleContains: String?
    public var identifier: String?
    public var value: String?
    public var description: String?
    public var descriptionContains: String?
    /// Case-insensitive substring match across `title`, `description`, `help`, and `value`.
    /// Use when you see visible text on screen but don't know which AX attribute carries it
    /// (SwiftUI puts labels in different attributes depending on Button/Text/Image variants).
    public var labelContains: String?
    public var maxResults: Int

    public init(role: String? = nil, title: String? = nil, titleContains: String? = nil,
                identifier: String? = nil, value: String? = nil,
                description: String? = nil, descriptionContains: String? = nil,
                labelContains: String? = nil,
                maxResults: Int = 20) {
        self.role = role
        self.title = title
        self.titleContains = titleContains
        self.identifier = identifier
        self.value = value
        self.description = description
        self.descriptionContains = descriptionContains
        self.labelContains = labelContains
        self.maxResults = maxResults
    }
}

public struct AXElementSearchResult: Sendable {
    public let element: AXElement
    public let path: String
    public let depth: Int
}

public struct AXElementSearch {
    public static func find(root: AXElement, criteria: AXElementSearchCriteria, maxDepth: Int = 10) -> [AXElementSearchResult] {
        var results: [AXElementSearchResult] = []
        bfs(root: root, criteria: criteria, maxDepth: maxDepth, results: &results)
        return results
    }

    private static func bfs(root: AXElement, criteria: AXElementSearchCriteria, maxDepth: Int,
                            results: inout [AXElementSearchResult]) {
        var queue: [(element: AXElement, path: String, depth: Int)] = [(root, "root", 0)]

        while !queue.isEmpty && results.count < criteria.maxResults {
            let (element, path, depth) = queue.removeFirst()

            if matches(element, criteria: criteria) {
                results.append(AXElementSearchResult(element: element, path: path, depth: depth))
            }

            if depth < maxDepth {
                for (i, child) in element.children.enumerated() {
                    let role = child.role ?? "element"
                    let name = child.title ?? child.identifier ?? "\(i)"
                    let childPath = "\(path)/\(role):\(name)"
                    queue.append((child, childPath, depth + 1))
                }
            }
        }
    }

    private static func matches(_ element: AXElement, criteria: AXElementSearchCriteria) -> Bool {
        if let role = criteria.role, element.role != role { return false }
        if let title = criteria.title, element.title != title { return false }
        if let contains = criteria.titleContains {
            guard let t = element.title, t.localizedCaseInsensitiveContains(contains) else { return false }
        }
        if let identifier = criteria.identifier, element.identifier != identifier { return false }
        if let value = criteria.value, element.stringValue != value { return false }
        if let description = criteria.description, element.label != description { return false }
        if let contains = criteria.descriptionContains {
            guard let d = element.label, d.localizedCaseInsensitiveContains(contains) else { return false }
        }
        if let contains = criteria.labelContains {
            let haystacks = [element.title, element.label, element.help, element.stringValue].compactMap { $0 }
            guard haystacks.contains(where: { $0.localizedCaseInsensitiveContains(contains) }) else { return false }
        }
        let anyCriterion = criteria.role != nil || criteria.title != nil || criteria.titleContains != nil
            || criteria.identifier != nil || criteria.value != nil
            || criteria.description != nil || criteria.descriptionContains != nil
            || criteria.labelContains != nil
        return anyCriterion
    }
}
