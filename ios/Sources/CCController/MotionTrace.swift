#if DEBUG
import QuartzCore
import SwiftUI
import UIKit

@MainActor
final class MotionTrace: NSObject {
    static let shared = MotionTrace()

    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var owner: MotionTrace?

        init(owner: MotionTrace) {
            self.owner = owner
        }

        @objc func tick(_ link: CADisplayLink) {
            owner?.sample(link)
        }
    }

    private weak var window: UIWindow?
    private weak var keyboardProbe: UIView?
    private weak var scrollView: UIScrollView?
    private var pinnedProvider: (() -> Bool)?
    private var scrollRegistrations: [ScrollRegistration] = []
    private var probes: [String: WeakView] = [:]
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private var flushTimer: Timer?
    private let writeQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "cc-controller").motion-trace", qos: .utility)
    private let fileURL: URL?
    private var pendingLines: [String] = []
    private var lastTimestamp: CFTimeInterval?
    private var frameCount = 0
    private var totalProbeCost = 0.0
    private var maximumProbeCost = 0.0
    private var didWriteStats = false
    private var keyboardVisible = false
    private var metaWritten = false

    let isEnabled: Bool

    private struct WeakView {
        weak var value: UIView?
    }

    private final class ScrollRegistration {
        let token: UUID
        weak var scrollView: UIScrollView?
        let pinnedProvider: () -> Bool

        init(scrollView: UIScrollView, pinnedProvider: @escaping () -> Bool) {
            token = UUID()
            self.scrollView = scrollView
            self.pinnedProvider = pinnedProvider
        }
    }

    private override init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-CCMotionTrace"),
           arguments.indices.contains(index + 1),
           !arguments[index + 1].isEmpty {
            isEnabled = true
            let name = URL(fileURLWithPath: arguments[index + 1]).lastPathComponent
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            fileURL = documents.appendingPathComponent(name.isEmpty ? "motion-trace.jsonl" : name)
        } else {
            isEnabled = false
            fileURL = nil
        }
        super.init()
        guard isEnabled, let fileURL else { return }
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        start()
    }

    private func start() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardDidHideNotification,
            UIApplication.willResignActiveNotification,
            UIApplication.willTerminateNotification,
            Notification.Name("CCMotionTraceEvent"),
        ]
        for name in names {
            center.addObserver(self, selector: #selector(handleNotification(_:)), name: name, object: nil)
        }
        displayLinkTarget = DisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: displayLinkTarget!, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(periodicFlush), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    @objc private func periodicFlush() {
        guard !didWriteStats else { return }
        let mean = frameCount == 0 ? 0 : totalProbeCost / Double(frameCount)
        recordEvent("probeStats", data: ["meanMs": mean, "maxMs": maximumProbeCost])
        flush()
    }

    func registerProbe(id: String, view: UIView) {
        guard isEnabled else { return }
        probes[id] = WeakView(value: view)
    }

    func unregisterProbe(id: String, view: UIView) {
        guard probes[id]?.value === view else { return }
        probes.removeValue(forKey: id)
    }

    func installKeyboardProbe(in root: UIView) {
        guard isEnabled, keyboardProbe == nil else { return }
        let marker = UIView(frame: .zero)
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.isHidden = true
        marker.isAccessibilityElement = false
        root.addSubview(marker)
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            marker.topAnchor.constraint(equalTo: root.keyboardLayoutGuide.topAnchor),
            marker.widthAnchor.constraint(equalToConstant: 1),
            marker.heightAnchor.constraint(equalToConstant: 1),
        ])
        keyboardProbe = marker
    }

    @discardableResult
    func registerScrollView(_ scrollView: UIScrollView, pinned: @escaping () -> Bool) -> UUID? {
        guard isEnabled else { return nil }
        let registration = ScrollRegistration(scrollView: scrollView, pinnedProvider: pinned)
        scrollRegistrations.append(registration)
        self.scrollView = scrollView
        pinnedProvider = pinned
        return registration.token
    }

    func unregisterScrollView(_ scrollView: UIScrollView, token: UUID?) {
        guard let token,
              let index = scrollRegistrations.firstIndex(where: { $0.token == token && $0.scrollView === scrollView }) else { return }
        scrollRegistrations.remove(at: index)
        guard self.scrollView === scrollView, scrollRegistrations.last?.scrollView != nil else {
            if scrollRegistrations.isEmpty {
                self.scrollView = nil
                pinnedProvider = nil
            }
            return
        }
        let registration = scrollRegistrations.last!
        self.scrollView = registration.scrollView
        pinnedProvider = registration.pinnedProvider
    }

    func recordEvent(_ name: String, data: [String: Any] = [:]) {
        guard isEnabled else { return }
        var object: [String: Any] = ["t": "event", "ts": CACurrentMediaTime(), "name": name]
        if !data.isEmpty { object["d"] = data }
        append(object)
    }

    func recordPin(before: CGFloat, after: CGFloat, reason: String) {
        recordEvent("pin", data: ["before": before, "after": after, "reason": reason])
    }

    func recordComposerCleared() {
        guard isEnabled else { return }
        let before = probes["composer"]?.value?.bounds.height ?? 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let after = self.probes["composer"]?.value?.bounds.height ?? 0
            self.recordEvent("composerCleared", data: ["heightBefore": before, "heightAfter": after])
        }
    }

    @objc private func handleNotification(_ note: Notification) {
        switch note.name {
        case UIResponder.keyboardWillShowNotification:
            keyboardNotification(note, name: "keyboardWillShow", visible: true)
        case UIResponder.keyboardWillHideNotification:
            keyboardNotification(note, name: "keyboardWillHide", visible: false)
        case UIResponder.keyboardDidShowNotification:
            keyboardNotification(note, name: "keyboardDidShow", visible: true)
        case UIResponder.keyboardDidHideNotification:
            keyboardNotification(note, name: "keyboardDidHide", visible: false)
        case UIApplication.willResignActiveNotification, UIApplication.willTerminateNotification:
            stopAndFlush()
        case Notification.Name("CCMotionTraceEvent"):
            guard let name = note.userInfo?["name"] as? String else { return }
            recordEvent(name, data: note.userInfo?["data"] as? [String: Any] ?? [:])
        default:
            break
        }
    }

    private func keyboardNotification(_ note: Notification, name: String, visible: Bool) {
        keyboardVisible = visible
        let userInfo = note.userInfo ?? [:]
        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        let curve = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? 0
        let frame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let begin = (userInfo[UIResponder.keyboardFrameBeginUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let beginY = window.map { $0.convert(begin, from: nil).minY } ?? begin.minY
        let endY = window.map { $0.convert(frame, from: nil).minY } ?? frame.minY
        recordEvent(name, data: [
            "duration": duration,
            "curve": curve,
            "beginY": beginY,
            "endY": endY,
        ])
    }

    private func stopAndFlush() {
        displayLink?.invalidate()
        displayLink = nil
        flushTimer?.invalidate()
        flushTimer = nil
        guard !didWriteStats else {
            flush()
            return
        }
        didWriteStats = true
        let mean = frameCount == 0 ? 0 : totalProbeCost / Double(frameCount)
        recordEvent("probeStats", data: ["meanMs": mean, "maxMs": maximumProbeCost])
        flush()
    }

    private func sample(_ link: CADisplayLink) {
        let started = CACurrentMediaTime()
        guard let window = activeWindow() else { return }
        self.window = window
        writeMetaIfNeeded(window: window)
        let timestamp = CACurrentMediaTime()
        let dt = lastTimestamp.map { timestamp - $0 } ?? 0
        lastTimestamp = timestamp

        let windowRect = windowRect(for: window)
        let keyboardRect = keyboardProbe.map { rect(for: $0, in: window) }
        let composerRect = probes["composer"]?.value.map { rect(for: $0, in: window) }
        let scrollRect = scrollView.map { rect(for: $0, in: window) }
        let viewportTop = scrollRect?.minY ?? windowRect.minY
        let viewportBottom = scrollRect?.maxY ?? windowRect.maxY
        let rows = probes.compactMap { id, weakView -> [String: Any]? in
            guard id != "composer", let view = weakView.value,
                  isVisibleProbe(view, in: window) else { return nil }
            let value = clippedProbeRect(for: view, in: window)
            guard value.intersects(CGRect(x: windowRect.minX, y: viewportTop, width: windowRect.width, height: viewportBottom - viewportTop)) else { return nil }
            return ["id": id, "y0": value.minY, "y1": value.maxY]
        }.sorted { ($0["y0"] as? CGFloat ?? 0) < ($1["y0"] as? CGFloat ?? 0) }

        var frame: [String: Any] = [
            "t": "frame",
            "ts": timestamp,
            "dt": dt,
            "kb": keyboardRect?.minY ?? windowRect.maxY,
            "kbVisible": keyboardVisible,
            "composerTop": composerRect?.minY ?? windowRect.maxY,
            "composerBottom": composerRect?.maxY ?? windowRect.maxY,
            "viewportTop": viewportTop,
            "viewportBottom": viewportBottom,
            "offsetY": scrollView.map { presentationOffsetY(for: $0) } ?? 0,
            "contentH": scrollView?.contentSize.height ?? 0,
            "insetBottom": scrollView?.adjustedContentInset.bottom ?? 0,
            "pinned": pinnedProvider?() ?? false,
            "tracking": scrollView.map { $0.isTracking || $0.isDragging } ?? false,
            "decelerating": scrollView?.isDecelerating ?? false,
            "dragging": scrollView.map { $0.isTracking || $0.isDragging || $0.isDecelerating } ?? false,
            "rows": rows,
        ]
        if !frame.keys.contains("rows") { frame["rows"] = [] }
        append(frame)
        frameCount += 1
        let costMs = (CACurrentMediaTime() - started) * 1000
        totalProbeCost += costMs
        maximumProbeCost = max(maximumProbeCost, costMs)
        if pendingLines.count >= 120 { flush() }
    }

    private func isVisibleProbe(_ view: UIView, in window: UIWindow) -> Bool {
        guard view.window === window else { return false }
        var ancestor = view.superview
        while let current = ancestor, current !== window {
            let layer = current.layer.presentation() ?? current.layer
            if current.isHidden || layer.opacity < 0.01 { return false }
            ancestor = current.superview
        }
        return true
    }

    private func activeWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
    }

    private func writeMetaIfNeeded(window: UIWindow) {
        guard !metaWritten else { return }
        metaWritten = true
        let arguments = ProcessInfo.processInfo.arguments
        let scenario = argumentValue("-CCMotionScenario", in: arguments) ?? "unknown"
        let sha = argumentValue("-CCMotionSHA", in: arguments)
            ?? ProcessInfo.processInfo.environment["CCMotionBuildSHA"]
            ?? "unknown"
        let device = argumentValue("-CCMotionDevice", in: arguments)
            ?? ProcessInfo.processInfo.environment["CCMotionDevice"]
            ?? UIDevice.current.model
        let layer = window.layer.presentation() ?? window.layer
        append([
            "t": "meta",
            "v": 1,
            "scenario": scenario,
            // The controller's motion analyzer still requires this field.
            "engine": "collection",
            "device": device,
            "orientation": window.windowScene?.interfaceOrientation.isPortrait == true ? "portrait" : "landscape",
            "scale": window.screen.scale,
            "windowW": layer.bounds.width,
            "windowH": layer.bounds.height,
            "sha": sha,
        ])
    }

    private func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func windowRect(for window: UIWindow) -> CGRect {
        let layer = window.layer.presentation() ?? window.layer
        return layer.bounds
    }

    private func rect(for view: UIView, in window: UIWindow) -> CGRect {
        let source = view.layer.presentation() ?? view.layer
        let target = window.layer.presentation() ?? window.layer
        return source.convert(source.bounds, to: target)
    }

    private func clippedProbeRect(for view: UIView, in window: UIWindow) -> CGRect {
        let target = window.layer.presentation() ?? window.layer
        var visible = rect(for: view, in: window)
        var ancestor = view.superview
        while let current = ancestor, current !== scrollView, current !== window {
            if current.clipsToBounds {
                let layer = current.layer.presentation() ?? current.layer
                visible = visible.intersection(layer.convert(layer.bounds, to: target))
            }
            ancestor = current.superview
        }
        return visible
    }

    private func presentationOffsetY(for scrollView: UIScrollView) -> CGFloat {
        let layer = scrollView.layer.presentation() ?? scrollView.layer
        return layer.bounds.origin.y
    }

    private func append(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        pendingLines.append(line)
    }

    private func flush() {
        guard !pendingLines.isEmpty, let fileURL else { return }
        let lines = pendingLines.joined(separator: "\n") + "\n"
        pendingLines.removeAll(keepingCapacity: true)
        let path = fileURL.path
        writeQueue.async {
            guard let data = lines.data(using: .utf8), let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
        }
    }
}

@MainActor
struct MotionTraceProbe: View {
    let id: String
    @Environment(\.isTranscriptSizingPass) private var isTranscriptSizingPass

    @ViewBuilder
    var body: some View {
        if MotionTrace.shared.isEnabled {
            MotionTraceProbeRepresentable(id: id, isSizingPass: isTranscriptSizingPass)
        }
    }
}

@MainActor
private struct MotionTraceProbeRepresentable: UIViewRepresentable {
    let id: String
    let isSizingPass: Bool

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(id: id, isSizingPass: isSizingPass)
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.update(id: id, isSizingPass: isSizingPass)
    }

    final class ProbeView: UIView {
        private var probeID: String
        private var isSizingPass: Bool

        init(id: String, isSizingPass: Bool) {
            probeID = id
            self.isSizingPass = isSizingPass
            super.init(frame: .zero)
            alpha = 0
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(id: String, isSizingPass: Bool) {
            self.isSizingPass = isSizingPass
            guard !isSizingPass else { return }
            if probeID != id {
                MotionTrace.shared.unregisterProbe(id: probeID, view: self)
                probeID = id
            }
            MotionTrace.shared.registerProbe(id: probeID, view: self)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !isSizingPass else { return }
            if window == nil { MotionTrace.shared.unregisterProbe(id: probeID, view: self) }
            else { MotionTrace.shared.registerProbe(id: probeID, view: self) }
        }

    }
}


@MainActor
struct MotionTraceRootProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardProbeView { KeyboardProbeView() }
    func updateUIView(_ uiView: KeyboardProbeView, context: Context) {}

    final class KeyboardProbeView: UIView {
        private weak var marker: UIView?

        init() {
            super.init(frame: .zero)
            isHidden = true
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, let root = window.rootViewController?.view, marker == nil else { return }
            let marker = UIView(frame: .zero)
            marker.translatesAutoresizingMaskIntoConstraints = false
            marker.isHidden = true
            marker.isAccessibilityElement = false
            marker.accessibilityElementsHidden = true
            marker.isUserInteractionEnabled = false
            root.addSubview(marker)
            NSLayoutConstraint.activate([
                marker.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                marker.topAnchor.constraint(equalTo: root.keyboardLayoutGuide.topAnchor),
                marker.widthAnchor.constraint(equalToConstant: 1),
                marker.heightAnchor.constraint(equalToConstant: 1),
            ])
            self.marker = marker
            MotionTrace.shared.installKeyboardProbe(in: root)
        }

        deinit { marker?.removeFromSuperview() }
    }
}
#endif
