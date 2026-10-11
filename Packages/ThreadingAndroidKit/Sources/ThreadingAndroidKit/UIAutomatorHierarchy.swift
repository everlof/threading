import Foundation

/// One node of `uiautomator dump`'s window hierarchy, in device pixels with a top-left origin.
public struct AndroidUINode: Equatable, Sendable {
    public var className: String
    public var text: String
    public var contentDescription: String
    public var resourceID: String
    public var packageName: String
    public var bounds: CGRectValue
    public var isEnabled: Bool
    public var isClickable: Bool
    public var isFocusable: Bool
    public var isScrollable: Bool
    public var isCheckable: Bool
    public var isChecked: Bool
    public var isPassword: Bool
    public var isSelected: Bool
    public var children: [AndroidUINode]

    public struct CGRectValue: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public init(
        className: String, text: String, contentDescription: String, resourceID: String, packageName: String,
        bounds: CGRectValue, isEnabled: Bool, isClickable: Bool, isFocusable: Bool, isScrollable: Bool,
        isCheckable: Bool, isChecked: Bool, isPassword: Bool, isSelected: Bool, children: [AndroidUINode]
    ) {
        self.className = className
        self.text = text
        self.contentDescription = contentDescription
        self.resourceID = resourceID
        self.packageName = packageName
        self.bounds = bounds
        self.isEnabled = isEnabled
        self.isClickable = isClickable
        self.isFocusable = isFocusable
        self.isScrollable = isScrollable
        self.isCheckable = isCheckable
        self.isChecked = isChecked
        self.isPassword = isPassword
        self.isSelected = isSelected
        self.children = children
    }

    public var isInteractive: Bool { isClickable || isCheckable || isScrollable || className.hasSuffix("EditText") }
}

/// Parses the XML `uiautomator dump` writes, bounded in bytes and nodes before anything is built.
/// The synthetic root spans the whole display (the union of the top-level windows' bounds), so
/// every node's bounds normalize against it the way an iOS tree's root frame does.
public enum UIAutomatorHierarchy {
    public static let maximumBytes = 4 * 1024 * 1024
    public static let maximumNodes = 5_000

    public static func parse(_ data: Data, maximumNodes: Int = maximumNodes) throws -> AndroidUINode {
        guard data.count <= maximumBytes else { throw AndroidRecordError.hierarchyTooLarge }
        // `uiautomator dump /dev/stdout` appends "UI hierchary dumped to: …" after the document.
        let document: Data
        if let end = data.range(of: Data("</hierarchy>".utf8)) {
            document = data.subdata(in: data.startIndex..<end.upperBound)
        } else {
            throw AndroidRecordError.malformedHierarchy("The device returned no window hierarchy.")
        }
        let delegate = Delegate(maximumNodes: maximumNodes)
        let parser = XMLParser(data: document)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else {
            throw delegate.failure ?? AndroidRecordError.malformedHierarchy(
                parser.parserError?.localizedDescription ?? "Unreadable window hierarchy."
            )
        }
        var root = delegate.root
        let union = root.children.reduce(nil as AndroidUINode.CGRectValue?) { partial, child in
            guard let partial else { return child.bounds }
            let minX = min(partial.x, child.bounds.x), minY = min(partial.y, child.bounds.y)
            let maxX = max(partial.x + partial.width, child.bounds.x + child.bounds.width)
            let maxY = max(partial.y + partial.height, child.bounds.y + child.bounds.height)
            return .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        root.bounds = union ?? root.bounds
        return root
    }

    /// `[left,top][right,bottom]`.
    static func bounds(_ value: String) -> AndroidUINode.CGRectValue? {
        let numbers = value.split(whereSeparator: { "[],".contains($0) }).compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] >= numbers[0], numbers[3] >= numbers[1] else { return nil }
        return .init(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let maximumNodes: Int
        var stack: [AndroidUINode] = []
        var root = AndroidUINode.empty(className: "hierarchy")
        var count = 0
        var failure: AndroidRecordError?

        init(maximumNodes: Int) { self.maximumNodes = maximumNodes }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            guard elementName == "node" else { return }
            count += 1
            guard count <= maximumNodes else {
                failure = .hierarchyTooLarge
                parser.abortParsing()
                return
            }
            func flag(_ name: String) -> Bool { attributes[name] == "true" }
            stack.append(AndroidUINode(
                className: attributes["class"] ?? "", text: attributes["text"] ?? "",
                contentDescription: attributes["content-desc"] ?? "", resourceID: attributes["resource-id"] ?? "",
                packageName: attributes["package"] ?? "",
                bounds: attributes["bounds"].flatMap(UIAutomatorHierarchy.bounds) ?? .init(x: 0, y: 0, width: 0, height: 0),
                isEnabled: flag("enabled"), isClickable: flag("clickable") || flag("long-clickable"),
                isFocusable: flag("focusable"), isScrollable: flag("scrollable"), isCheckable: flag("checkable"),
                isChecked: flag("checked"), isPassword: flag("password"), isSelected: flag("selected"), children: []
            ))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard elementName == "node", let node = stack.popLast() else { return }
            if stack.isEmpty { root.children.append(node) } else { stack[stack.count - 1].children.append(node) }
        }
    }
}

extension AndroidUINode {
    static func empty(className: String) -> AndroidUINode {
        AndroidUINode(
            className: className, text: "", contentDescription: "", resourceID: "", packageName: "",
            bounds: .init(x: 0, y: 0, width: 0, height: 0), isEnabled: true, isClickable: false,
            isFocusable: false, isScrollable: false, isCheckable: false, isChecked: false,
            isPassword: false, isSelected: false, children: []
        )
    }
}
