import AppKit

/// Interactive drawing surface. Maps view coordinates to image pixel coordinates and owns undo.
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    let doc: AnnotationDocument
    var tool: AnnotationTool = .arrow { didSet { toolChanged(from: oldValue) } }
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var onStateChange: (() -> Void)?

    private(set) var selected: Annotation?
    private var drafting: Annotation?
    private var dragAnchor: CGPoint?
    private var pendingCrop: CGRect?
    private var movedSinceMouseDown = false

    private struct Snapshot { let annotations: [Annotation]; let crop: CGRect? }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private var textField: NSTextField?
    private var editingText: Annotation?
    private var textOrigin: CGPoint = .zero

    init(document: AnnotationDocument) {
        doc = document
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private var scale: CGFloat {
        let v = doc.visibleRect
        let avail = bounds.insetBy(dx: 24, dy: 24)
        guard v.width > 0, v.height > 0, avail.width > 0, avail.height > 0 else { return 1 }
        return min(avail.width / v.width, avail.height / v.height, 1 / doc.pixelScale)
    }

    private var transform: CGAffineTransform {
        let v = doc.visibleRect, s = scale
        let origin = CGPoint(x: bounds.midX - v.width * s / 2, y: bounds.midY - v.height * s / 2)
        return CGAffineTransform(translationX: origin.x.rounded(), y: origin.y.rounded())
            .scaledBy(x: s, y: s)
            .translatedBy(x: -v.minX, y: -v.minY)
    }

    private func toImage(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil).applying(transform.inverted())
    }

    private func toView(_ r: CGRect) -> CGRect { r.applying(transform) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .select ? .arrow : (tool == .text ? .iBeam : .crosshair))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.13, alpha: 1).setFill()
        bounds.fill()

        let v = doc.visibleRect
        ctx.saveGState()
        ctx.concatenate(transform)
        ctx.setShadow(offset: CGSize(width: 0, height: -2 / scale), blur: 12 / scale,
                      color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(v)
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.clip(to: v)
        ctx.interpolationQuality = .high
        ctx.draw(doc.base, in: doc.imageRect)
        for a in doc.annotations where a !== editingText { AnnotationRenderer.draw(a, in: doc, ctx: ctx) }
        if let d = drafting { AnnotationRenderer.draw(d, in: doc, ctx: ctx) }
        ctx.restoreGState()

        if let crop = pendingCrop {
            let r = toView(crop)
            let path = NSBezierPath(rect: toView(v))
            path.appendRect(r)
            path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            path.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: r)
            border.setLineDash([5, 4], count: 2, phase: 0)
            border.stroke()
        }

        if let sel = selected, sel !== editingText {
            let r = toView(sel.bounds(pixelScale: doc.pixelScale)).insetBy(dx: -4, dy: -4)
            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    // MARK: Undo

    private func pushUndo() {
        undoStack.append(Snapshot(annotations: doc.annotations.map { $0.copy() }, crop: doc.cropRect))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        onStateChange?()
    }

    private func restore(_ s: Snapshot) {
        doc.annotations = s.annotations
        doc.cropRect = s.crop
        selected = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onStateChange?()
    }

    @objc func undo(_ sender: Any?) {
        commitText()
        guard let s = undoStack.popLast() else { return NSSound.beep() }
        redoStack.append(Snapshot(annotations: doc.annotations.map { $0.copy() }, crop: doc.cropRect))
        restore(s)
    }

    @objc func redo(_ sender: Any?) {
        guard let s = redoStack.popLast() else { return NSSound.beep() }
        undoStack.append(Snapshot(annotations: doc.annotations.map { $0.copy() }, crop: doc.cropRect))
        restore(s)
    }

    @objc func delete(_ sender: Any?) { deleteSelected() }

    /// Adds pixelate boxes over the given image rects as a single undoable step.
    func addRedactions(_ rects: [CGRect]) {
        guard !rects.isEmpty else { return }
        commitText()
        pushUndo()
        for r in rects {
            let a = Annotation(tool: .pixelate, start: r.origin, color: color, lineWidth: lineWidth)
            a.end = CGPoint(x: r.maxX, y: r.maxY)
            doc.annotations.append(a)
        }
        needsDisplay = true
    }

    private func deleteSelected() {
        guard let sel = selected else { return }
        pushUndo()
        doc.annotations.removeAll { $0 === sel }
        selected = nil
        needsDisplay = true
    }

    // MARK: Style changes apply to the selection too

    func applyColor(_ c: NSColor) {
        color = c
        if let sel = selected { pushUndo(); sel.color = c; needsDisplay = true }
        textField?.textColor = c
    }

    func applyLineWidth(_ w: CGFloat) {
        lineWidth = w
        if let sel = selected {
            pushUndo()
            sel.lineWidth = w
            if sel.tool == .text { sel.fontSize = Self.fontSize(for: w) }
            needsDisplay = true
        }
    }

    static func fontSize(for lineWidth: CGFloat) -> CGFloat { 12 + lineWidth * 2.5 }

    private func toolChanged(from old: AnnotationTool) {
        commitText()
        if old == .crop { pendingCrop = nil }
        if tool != .select { selected = nil }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let p = toImage(event)
        movedSinceMouseDown = false

        switch tool {
        case .select:
            selected = doc.annotations.last { $0.hitTest(p, pixelScale: doc.pixelScale) }
            if let sel = selected, sel.tool == .text, event.clickCount == 2 {
                beginTextEditing(at: sel.start, existing: sel)
                return
            }
            dragAnchor = selected == nil ? nil : p
        case .text:
            if let hit = doc.annotations.last(where: { $0.tool == .text && $0.hitTest(p, pixelScale: doc.pixelScale) }) {
                beginTextEditing(at: hit.start, existing: hit)
            } else {
                beginTextEditing(at: p, existing: nil)
            }
            return
        case .counter:
            pushUndo()
            let a = Annotation(tool: .counter, start: p, color: color, lineWidth: lineWidth)
            a.number = doc.nextCounterNumber
            doc.annotations.append(a)
        case .crop:
            dragAnchor = p
            pendingCrop = nil
        case .pen:
            let a = Annotation(tool: .pen, start: p, color: color, lineWidth: lineWidth)
            a.points = [p]
            drafting = a
        default:
            let highlight = tool == .highlighter && color == .systemRed ? NSColor.systemYellow : color
            drafting = Annotation(tool: tool, start: p, color: highlight, lineWidth: lineWidth)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        var p = toImage(event)
        switch tool {
        case .select:
            guard let sel = selected, let anchor = dragAnchor else { return }
            if !movedSinceMouseDown { pushUndo(); movedSinceMouseDown = true }
            sel.translate(dx: p.x - anchor.x, dy: p.y - anchor.y)
            dragAnchor = p
        case .crop:
            guard let a = dragAnchor else { return }
            pendingCrop = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
                .integral.intersection(doc.imageRect)
        case .pen:
            drafting?.points.append(p)
        default:
            guard let d = drafting else { return }
            if event.modifierFlags.contains(.shift) { p = constrain(p, from: d.start, tool: d.tool) }
            d.end = p
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let d = drafting {
            drafting = nil
            let big = d.tool == .pen ? d.points.count > 1 : hypot(d.end.x - d.start.x, d.end.y - d.start.y) > 3
            if big {
                pushUndo()
                doc.annotations.append(d)
            }
        }
        dragAnchor = tool == .crop ? dragAnchor : nil
        needsDisplay = true
    }

    private func constrain(_ p: CGPoint, from s: CGPoint, tool: AnnotationTool) -> CGPoint {
        let dx = p.x - s.x, dy = p.y - s.y
        switch tool {
        case .arrow, .line:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
        default:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Escape
            if pendingCrop != nil { pendingCrop = nil } else { selected = nil }
            needsDisplay = true
        case 36, 76: // Return
            applyCrop()
        case 51, 117: // Delete
            deleteSelected()
        default:
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.isEmpty || mods == .capsLock,
               let ch = event.charactersIgnoringModifiers?.lowercased().first,
               let t = AnnotationTool.allCases.first(where: { $0.shortcut == ch }) {
                tool = t
                onStateChange?()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    func applyCrop() {
        guard let crop = pendingCrop, crop.width >= 4, crop.height >= 4 else { return }
        pushUndo()
        doc.cropRect = crop
        pendingCrop = nil
        dragAnchor = nil
        needsDisplay = true
    }

    // MARK: Text editing

    private func beginTextEditing(at p: CGPoint, existing: Annotation?) {
        commitText()
        editingText = existing
        textOrigin = p
        let fontSize = (existing?.fontSize ?? Self.fontSize(for: lineWidth)) * doc.pixelScale * scale
        let field = NSTextField(string: existing?.text ?? "")
        field.font = .systemFont(ofSize: fontSize, weight: .bold)
        field.textColor = existing?.color ?? color
        field.backgroundColor = NSColor.white.withAlphaComponent(0.08)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = "Text"
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        let viewPoint = p.applying(transform)
        let height = ceil(fontSize * 1.3)
        field.frame = CGRect(x: viewPoint.x - 2, y: viewPoint.y - height, width: max(120, field.fittingSize.width + 20), height: height)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        field.frame.size.width = max(120, field.fittingSize.width + 20)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        if let existing = editingText {
            if text != existing.text {
                pushUndo()
                if text.isEmpty { doc.annotations.removeAll { $0 === existing } } else { existing.text = text }
            }
        } else if !text.isEmpty {
            pushUndo()
            let a = Annotation(tool: .text, start: textOrigin, color: color, lineWidth: lineWidth)
            a.text = text
            a.fontSize = Self.fontSize(for: lineWidth)
            doc.annotations.append(a)
        }
        editingText = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func finishEditing() {
        commitText()
        applyCrop()
    }
}
