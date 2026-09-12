import Foundation

// MARK: - 极简 TTML DOM
//
// TTML 是空格敏感的 XML，且用到了 ttm: / itunes: / amll: / tts: 多个命名空间前缀。
// 这里用 Foundation 的 XMLParser 建一棵最简节点树，保留「文本节点与子元素的有序交错」——
// 这一点是必须的：`<span>You</span> <span>said</span>` 中间那个空格是真实文本节点，
// 承载着英文词间空格，丢掉它会把整行拼成 "Yousaid"。
//
// 命名空间处理策略（与 AMLL 官方解析库 MeloX 的实现一致）：
//   shouldProcessNamespaces = false  → elementName / attributeDict 里保留原始前缀（"ttm:role"）
//   shouldReportNamespacePrefixes = true → qName 可用
// 然后一律按 localName（冒号后半段）匹配，这样 `ttm:role`、`itunes:key`、`xml:lang`
// 都能用不带前缀的名字取到，不用关心投稿者写的是哪个前缀。

final class AmllTtmlNode {
    enum Content {
        case text(String)
        case child(AmllTtmlNode)
    }

    let name: String
    let attributes: [String: String]
    var contents: [Content] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// 去掉命名空间前缀的标签名。`ttm:agent` → `agent`。
    var localName: String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    var children: [AmllTtmlNode] {
        contents.compactMap {
            guard case .child(let node) = $0 else { return nil }
            return node
        }
    }

    /// 按 localName 取属性值。`attribute("role")` 能命中 `ttm:role`。
    func attribute(_ names: String...) -> String? {
        for requested in names {
            if let value = attributes[requested] { return value }
            if let match = attributes.first(where: {
                $0.key.split(separator: ":").last.map(String.init) == requested
            }) {
                return match.value
            }
        }
        return nil
    }

    /// 是否带指定 role（`ttm:role="x-translation"` 等）。
    func hasRole(_ role: String) -> Bool {
        attributes.contains {
            $0.key.split(separator: ":").last == "role" && $0.value == role
        }
    }

    /// 深度优先收集满足条件的子孙节点（含自身）。
    func descendants(where predicate: (AmllTtmlNode) -> Bool) -> [AmllTtmlNode] {
        var result: [AmllTtmlNode] = []
        if predicate(self) { result.append(self) }
        for child in children {
            result.append(contentsOf: child.descendants(where: predicate))
        }
        return result
    }

    /// 递归拼接全部文本；`excludingRoles` 里的 role 子树整棵跳过。
    func text(excludingRoles excludedRoles: Set<String> = []) -> String {
        if excludedRoles.contains(where: hasRole) { return "" }
        return contents.map { content in
            switch content {
            case .text(let text): return text
            case .child(let child): return child.text(excludingRoles: excludedRoles)
            }
        }.joined()
    }
}

enum AmllTtmlDocument {
    /// 解析 TTML 字符串；失败返回 nil。
    static func parse(_ source: String) -> AmllTtmlNode? {
        guard let data = source.data(using: .utf8) else { return nil }
        let builder = AmllTtmlDocumentBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true
        guard parser.parse() else { return nil }
        return builder.root
    }
}

private final class AmllTtmlDocumentBuilder: NSObject, XMLParserDelegate {
    private(set) var root: AmllTtmlNode?
    private var stack: [AmllTtmlNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = AmllTtmlNode(name: qName ?? elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.contents.append(.child(node))
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let node = stack.last else { return }
        // 与相邻文本节点合并：XMLParser 对同一段文本可能分多次回调。
        if case .text(let existing)? = node.contents.last {
            node.contents[node.contents.count - 1] = .text(existing + string)
        } else {
            node.contents.append(.text(string))
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }
}
