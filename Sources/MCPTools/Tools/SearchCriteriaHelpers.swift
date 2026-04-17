import Foundation
import MCPServer
import AccessibilityEngine

extension AXElementSearchCriteria {
    /// Build search criteria from a tool-handler `args` object. Honors all eight
    /// matcher fields plus `maxResults`. Callers pass a single max (usually 1 for
    /// interaction tools, 20 for inspection tools).
    init(from args: JSONValue?, maxResults: Int) {
        self.init(
            role: args?["role"]?.stringValue,
            title: args?["title"]?.stringValue,
            titleContains: args?["titleContains"]?.stringValue,
            identifier: args?["identifier"]?.stringValue,
            value: args?["value"]?.stringValue,
            description: args?["description"]?.stringValue,
            descriptionContains: args?["descriptionContains"]?.stringValue,
            labelContains: args?["labelContains"]?.stringValue,
            maxResults: maxResults
        )
    }
}
