import AppKit
import Foundation

@MainActor
func near(_ value: CGFloat, _ expected: CGFloat, _ name: String, tolerance: CGFloat = 0.05) {
    precondition(abs(value - expected) < tolerance, "\(name): \(value), expected \(expected)")
}

@MainActor
func fixed(_ width: CGFloat, _ height: CGFloat) -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: width).isActive = true
    view.heightAnchor.constraint(equalToConstant: height).isActive = true
    return view
}

@MainActor
func testHorizontal() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let first = fixed(40, 20)
    let spring = NSView()
    spring.translatesAutoresizingMaskIntoConstraints = false
    let last = fixed(60, 30)
    let stack = NSStackView(views: [first, spring, last])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 4
    stack.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 7, right: 20)
    stack.setCustomSpacing(0, after: first)
    stack.setCustomSpacing(0, after: spring)
    root.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        stack.topAnchor.constraint(equalTo: root.topAnchor),
        stack.heightAnchor.constraint(equalToConstant: 50),
        spring.widthAnchor.constraint(greaterThanOrEqualToConstant: 10)
    ])
    root.layoutSubtreeIfNeeded()
    near(first.frame.minX, 10, "horizontal first x")
    near(spring.frame.minX, 50, "horizontal spring x")
    near(spring.frame.width, 170, "horizontal spring width")
    near(last.frame.minX, 220, "horizontal last x")
    near(last.frame.midY, 25, "horizontal inset center")
    last.isHidden = true
    root.layoutSubtreeIfNeeded()
    precondition(stack.arrangedSubviews.count == 3)
    near(spring.frame.width, 230, "hidden member collapses")
    precondition(stack.customSpacing(after: first) == 0)
    stack.removeArrangedSubview(first)
    precondition(first.superview === stack)
    first.removeFromSuperview()
    spring.removeFromSuperview()
    precondition(stack.arrangedSubviews.count == 1)
}

@MainActor
func testVertical() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    let first = fixed(50, 20)
    let second = fixed(60, 30)
    let stack = NSStackView(views: [first, second])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 5, left: 3, bottom: 7, right: 11)
    root.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
        stack.topAnchor.constraint(equalTo: root.topAnchor),
        stack.widthAnchor.constraint(equalToConstant: 150)
    ])
    root.layoutSubtreeIfNeeded()
    near(stack.frame.height, 68, "vertical fitted height")
    near(first.frame.minX, 3, "vertical first x")
    near(second.frame.minX, 3, "vertical second x")
    near(first.frame.minY - second.frame.maxY, 6, "vertical gap")
}

@MainActor
func testVerticalCenter() {
    let defaultStack = NSStackView()
    defaultStack.orientation = .vertical
    precondition(defaultStack.alignment == .centerX)
    defaultStack.orientation = .horizontal
    precondition(defaultStack.alignment == .centerY)

    let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    let child = fixed(50, 20)
    let stack = NSStackView(views: [child])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.edgeInsets = NSEdgeInsets(top: 5, left: 3, bottom: 7, right: 11)
    root.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
        stack.topAnchor.constraint(equalTo: root.topAnchor),
        stack.widthAnchor.constraint(equalToConstant: 150)
    ])
    root.layoutSubtreeIfNeeded()
    near(child.frame.midX, 75, "vertical center ignores asymmetric insets")
}

@MainActor
func testEqual() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let views = (0..<3).map { _ in NSView() }
    let stack = NSStackView(views: views)
    stack.distribution = .fillEqually
    stack.spacing = 10
    root.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        stack.topAnchor.constraint(equalTo: root.topAnchor),
        stack.heightAnchor.constraint(equalToConstant: 30)
    ])
    root.layoutSubtreeIfNeeded()
    for view in views { near(view.frame.width, 280.0 / 3.0, "equal width", tolerance: 1) }
    stack.insertArrangedSubview(views[2], at: 0)
    precondition(stack.arrangedSubviews[0] === views[2])
}

@MainActor
func testMoveBetweenStacks() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let first = NSStackView()
    let second = NSStackView()
    first.translatesAutoresizingMaskIntoConstraints = false
    second.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(first)
    root.addSubview(second)
    NSLayoutConstraint.activate([
        first.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        first.topAnchor.constraint(equalTo: root.topAnchor),
        second.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 100),
        second.topAnchor.constraint(equalTo: root.topAnchor)
    ])
    let child = NSView()
    first.addArrangedSubview(child)
    child.widthAnchor.constraint(equalToConstant: 40).isActive = true
    child.heightAnchor.constraint(equalToConstant: 20).isActive = true
    root.layoutSubtreeIfNeeded()
    near(first.frame.width, 40, "first stack content width")

    second.addArrangedSubview(child)
    root.layoutSubtreeIfNeeded()
    precondition(first.arrangedSubviews.isEmpty)
    near(child.frame.width, 40, "moved child keeps width")
    near(second.frame.width, 40, "second stack content width")
}

@MainActor
func testSetViewsReplacesGravity() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.spacing = 5
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
        stack.topAnchor.constraint(equalTo: root.topAnchor),
        stack.heightAnchor.constraint(equalToConstant: 30)
    ])
    let first = fixed(20, 12)
    let retained = fixed(30, 12)
    let added = fixed(40, 12)
    stack.setViews([first, retained], in: .leading)
    root.layoutSubtreeIfNeeded()
    near(stack.frame.width, 55, "initial setViews width")
    near(retained.frame.minX, 25, "initial retained position")
    let oldWidth = first.widthAnchor.constraint(equalToConstant: 20)
    oldWidth.isActive = true

    stack.setViews([retained, added], in: .leading)
    root.layoutSubtreeIfNeeded()
    precondition(first.superview == nil, "setViews removes the replaced view from the hierarchy")
    precondition(oldWidth.isActive && first.constraints.contains(where: { $0 === oldWidth }),
                 "a removed view retains its own width constraint")
    precondition(!stack.constraints.contains(where: { $0 === oldWidth }),
                 "a removed view leaves no stale constraint in the stack")
    precondition(retained.superview === stack && added.superview === stack)
    precondition(stack.arrangedSubviews.count == 2)
    near(stack.frame.width, 75, "replacement width")
    near(added.frame.minX, 35, "replacement position")

    added.isHidden = true
    root.layoutSubtreeIfNeeded()
    near(stack.frame.width, 30, "hidden replacement loses its slot")
    stack.setViews([], in: .leading)
    precondition(stack.arrangedSubviews.isEmpty && stack.subviews.isEmpty)
    precondition(retained.superview == nil && added.superview == nil)
}

@MainActor
func testSetViewsAndLaterAddition() {
    let stack = NSStackView()
    stack.orientation = .vertical
    let first = NSView()
    let second = NSView()
    let last = NSView()
    stack.setViews([first, second], in: .top)
    stack.addArrangedSubview(last)
    precondition(stack.arrangedSubviews.count == 3)
    stack.setViews([second], in: .top)
    precondition(first.superview == nil)
    precondition(last.superview == nil && second.superview === stack)
    precondition(stack.arrangedSubviews.count == 1 && stack.arrangedSubviews[0] === second)
}

@MainActor
func testFittingSize() {
    let plain = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    near(plain.fittingSize.width, 0, "plain view has no fitted width")
    near(plain.fittingSize.height, 0, "plain view has no fitted height")

    let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let child = NSView()
    child.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(child)
    let width = child.widthAnchor.constraint(equalToConstant: 80)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
        child.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
        child.topAnchor.constraint(equalTo: root.topAnchor, constant: 5),
        child.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -7),
        width,
        child.heightAnchor.constraint(equalToConstant: 30)
    ])
    near(root.fittingSize.width, 102, "constraint-backed fitting width")
    near(root.fittingSize.height, 42, "constraint-backed fitting height")
    near(root.frame.width, 200, "measurement preserves root width")
    near(root.frame.height, 100, "measurement preserves root height")
    width.constant = 90
    near(root.fittingSize.width, 112, "fitting responds to a changed constraint")
    root.layoutSubtreeIfNeeded()
    near(root.frame.width, 200, "live layout keeps its own root width")
    near(root.fittingSize.width, 112, "live layout does not poison fitting solve")
}

@MainActor
func testGravityLeavesSpareSpace() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
    let vertical = NSStackView()
    vertical.orientation = .vertical
    vertical.alignment = .leading
    vertical.spacing = 5
    vertical.translatesAutoresizingMaskIntoConstraints = false
    let top = fixed(40, 20)
    let next = fixed(40, 15)
    vertical.setViews([top, next], in: .top)
    root.addSubview(vertical)
    NSLayoutConstraint.activate([
        vertical.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        vertical.topAnchor.constraint(equalTo: root.topAnchor),
        vertical.widthAnchor.constraint(equalToConstant: 100),
        vertical.heightAnchor.constraint(equalToConstant: 100)
    ])
    root.layoutSubtreeIfNeeded()
    near(top.frame.height, 20, "top child keeps its fixed height")
    near(next.frame.height, 15, "next child keeps its fixed height")
    near(top.frame.maxY, 100, "top gravity places first child at top")
    near(next.frame.maxY, 75, "top gravity leaves spare room below")

    let horizontal = NSStackView()
    horizontal.orientation = .horizontal
    horizontal.spacing = 5
    horizontal.translatesAutoresizingMaskIntoConstraints = false
    let leading = fixed(20, 20)
    let following = fixed(15, 20)
    horizontal.setViews([leading, following], in: .leading)
    root.addSubview(horizontal)
    NSLayoutConstraint.activate([
        horizontal.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        horizontal.topAnchor.constraint(equalTo: vertical.bottomAnchor),
        horizontal.widthAnchor.constraint(equalToConstant: 100),
        horizontal.heightAnchor.constraint(equalToConstant: 20)
    ])
    root.layoutSubtreeIfNeeded()
    near(following.frame.maxX, 40, "leading gravity leaves spare room after fixed children")
}

@MainActor
func testTopGravityFlexibleSpring() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 5
    stack.translatesAutoresizingMaskIntoConstraints = false
    let top = fixed(40, 20)
    let spring = NSView()
    spring.translatesAutoresizingMaskIntoConstraints = false
    spring.widthAnchor.constraint(equalToConstant: 40).isActive = true
    let bottom = fixed(40, 15)
    stack.setViews([top, spring, bottom], in: .top)
    root.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        stack.topAnchor.constraint(equalTo: root.topAnchor),
        stack.widthAnchor.constraint(equalToConstant: 100),
        stack.heightAnchor.constraint(equalToConstant: 100)
    ])
    root.layoutSubtreeIfNeeded()
    near(spring.frame.height, 55, "vertical spring absorbs spare height")
    near(bottom.frame.minY, 0, "spring pushes bottom child to edge")
}

@main
struct StackContract {
    @MainActor static func main() {
        testHorizontal()
        testVertical()
        testVerticalCenter()
        testEqual()
        testMoveBetweenStacks()
        testSetViewsReplacesGravity()
        testSetViewsAndLaterAddition()
        testFittingSize()
        testGravityLeavesSpareSpace()
        testTopGravityFlexibleSpring()
        print("stack contract passed")
    }
}
