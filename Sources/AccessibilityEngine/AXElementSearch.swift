import Foundation

public struct AXElementSearchCriteria: Sendable {
    public var role: String?
    public var title: String?
    public var titleContains: String?
    public var identifier: String?
    public var value: String?
    public var maxResults: Int

    public init(role: String? = nil, title: String? = nil, titleContains: String? = nil,
                identifier: String? = nil, value: String? = nil, maxResults: Int = 20) {
        self.role = role
        self.title = title
        self.titleContains = titleContains
        self.identifier = identifier
        self.value = value
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
        // At least one criterion must be specified
        if criteria.role == nil && criteria.title == nil && criteria.titleContains == nil
            && criteria.identifier == nil && criteria.value == nil {
            return false
        }
        return true
    }
}
