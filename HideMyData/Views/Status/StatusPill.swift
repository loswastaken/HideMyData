import SwiftUI

struct StatusPill: View {
    let detector: PIIDetector
    let pdfRedactor: PDFRedactor
    let imageRedactor: ImageRedactor
    let inputMode: InputMode
    let showingDocument: Bool

    @State private var dismissed = false

    private var resolvedContent: StatusPillContent? {
        StatusPillContent.resolve(
            detector: detector,
            pdfRedactor: pdfRedactor,
            imageRedactor: imageRedactor,
            inputMode: inputMode,
            showingDocument: showingDocument
        )
    }

    var body: some View {
        let content = resolvedContent
        let visible = (content?.autoDismissAfter != nil && dismissed) ? nil : content

        Group {
            if let visible {
                HStack(spacing: 8) {
                    visible.kind.icon
                    Text(visible.text)
                        .font(.callout)
                        .foregroundStyle(visible.kind.foreground)
                        .lineLimit(visible.maxLines)
                        .fixedSize(horizontal: false, vertical: visible.maxLines > 1)
                        .frame(maxWidth: visible.maxLines > 1 ? 460 : nil, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(visible.kind.tint), in: .capsule)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.smooth(duration: 0.25), value: visible.text)
            }
        }
        .task(id: content) {
            dismissed = false
            guard let timeout = content?.autoDismissAfter else { return }
            try? await Task.sleep(for: timeout)
            dismissed = true
        }
    }
}

struct StatusPillContent: Equatable {
    enum Kind: Equatable {
        case progress
        case info(String)
        case success(String)
        case warning(String)

        @ViewBuilder var icon: some View {
            switch self {
            case .progress:
                ProgressView().controlSize(.small)
            case .info(let symbol):
                Image(systemName: symbol)
            case .success(let symbol):
                Image(systemName: symbol).foregroundStyle(.green)
            case .warning(let symbol):
                Image(systemName: symbol).foregroundStyle(.red)
            }
        }

        var foreground: AnyShapeStyle {
            switch self {
            case .progress, .info: AnyShapeStyle(.secondary)
            case .success: AnyShapeStyle(.primary)
            case .warning: AnyShapeStyle(.red)
            }
        }

        var tint: Color {
            switch self {
            case .progress: .accentColor.opacity(0.20)
            case .info: .clear
            case .success: .green.opacity(0.15)
            case .warning: .red.opacity(0.18)
            }
        }
    }

    let kind: Kind
    let text: LocalizedStringKey
    let autoDismissAfter: Duration?
    let maxLines: Int

    init(kind: Kind, text: LocalizedStringKey, autoDismissAfter: Duration? = nil, maxLines: Int = 1) {
        self.kind = kind
        self.text = text
        self.autoDismissAfter = autoDismissAfter
        self.maxLines = maxLines
    }

    static func resolve(
        detector: PIIDetector,
        pdfRedactor: PDFRedactor,
        imageRedactor: ImageRedactor,
        inputMode: InputMode,
        showingDocument: Bool
    ) -> StatusPillContent? {
        if let dpill = detector.statusPill { return dpill }
        // A PDF that failed to open (e.g. password cancelled) must be reported even when
        // the home screen is showing, otherwise the failure is invisible.
        if !showingDocument, inputMode == .pdf, case .failed = pdfRedactor.phase {
            return pdfRedactor.statusPill
        }
        guard showingDocument else { return nil }
        switch inputMode {
        case .pdf: return pdfRedactor.statusPill
        case .image: return imageRedactor.statusPill
        }
    }
}

private extension PIIDetector {
    var statusPill: StatusPillContent? {
        switch phase {
        case .ready: nil
        case .running:
            .init(kind: .progress, text: "Detecting…")
        case .loadingModel, .warmingUp:
            .init(kind: .progress, text: "\(statusText)")
        case .failed(let msg):
            .init(kind: .warning("exclamationmark.triangle.fill"), text: "\(msg)")
        default: nil
        }
    }
}

private extension PDFRedactor {
    var statusPill: StatusPillContent? {
        guard !statusText.isEmpty, phase != .empty else { return nil }
        let placed = redactionCount
        let warning = StatusPillContent.Kind.warning("exclamationmark.triangle.fill")
        return switch phase {
        case .detected(let report):
            if let review = report.reviewSummary {
                // Something was detected but not redacted: stay visible until the user acts.
                StatusPillContent(kind: warning, text: "^[\(placed) redaction](inflect: true). \(review)", maxLines: 3)
            } else if let notice = report.notice {
                // Nothing readable on some page: neutral, but it stays until the user acts.
                StatusPillContent(kind: .info("exclamationmark.circle"), text: "^[\(placed) redaction](inflect: true). \(notice)", maxLines: 3)
            } else if placed == 0 {
                StatusPillContent(
                    kind: .info("info.circle"),
                    text: report.detectedSpanCount == 0 ? "No personal data found" : "No redactions",
                    autoDismissAfter: .seconds(4)
                )
            } else {
                StatusPillContent(
                    kind: .success("checkmark.seal.fill"),
                    text: "^[\(placed) redaction](inflect: true)",
                    autoDismissAfter: .seconds(3)
                )
            }
        case .loaded where placed > 0:
            StatusPillContent(
                kind: .info("rectangle.fill"),
                text: "^[\(placed) redaction](inflect: true)",
                autoDismissAfter: .seconds(3)
            )
        case .saved(let url):
            if let review = detectionReport?.reviewSummary {
                // Saved anyway: the file may still contain what could not be redacted.
                StatusPillContent(kind: warning, text: "Saved \(url.lastPathComponent). \(review)", maxLines: 3)
            } else {
                StatusPillContent(kind: .success("tray.and.arrow.down.fill"), text: "\(url.lastPathComponent)")
            }
        case .detecting:
            StatusPillContent(kind: .progress, text: "Detecting…")
        case .failed(let msg):
            StatusPillContent(kind: warning, text: "\(msg)", maxLines: 3)
        default: nil
        }
    }
}

private extension ImageRedactor {
    var statusPill: StatusPillContent? {
        guard !statusText.isEmpty, phase != .empty else { return nil }
        return switch phase {
        case .redacted(_, let rects):
            StatusPillContent(
                kind: .success("checkmark.seal.fill"),
                text: "^[\(rects) redaction](inflect: true)",
                autoDismissAfter: .seconds(3)
            )
        case .saved(let url):
            StatusPillContent(kind: .success("tray.and.arrow.down.fill"), text: "\(url.lastPathComponent)")
        case .detecting:
            StatusPillContent(kind: .progress, text: "Detecting…")
        case .failed(let msg):
            StatusPillContent(kind: .warning("exclamationmark.triangle.fill"), text: "\(msg)")
        default: nil
        }
    }
}
