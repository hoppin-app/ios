//
//  ChatMessageBubble.swift
//  HopChat-1
//
//  One message in a thread: text or image, translation marker, deleted
//  placeholder, and (for outgoing messages) a delivery-status tick.
//
//  Accessibility: the whole bubble is a single VoiceOver element that reads
//  "<sender>, <text>, <time>, <status>". Decoration (bubble tail, tick glyphs,
//  avatar colours) is hidden.
//
//  Dynamic Type: every size comes from a text style, so bubbles grow and wrap
//  at accessibility sizes instead of truncating.
//

import SwiftUI
import UIKit
import os

// MARK: - Formatters

nonisolated enum ChatFormatters {

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static let daySeparator: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    static func time(_ date: Date) -> String { time.string(from: date) }

    /// Compact stamp for a conversation row: time today, "Yesterday", else date.
    static func listStamp(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time.string(from: date) }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return shortDate.string(from: date)
    }

    static func daySeparator(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return daySeparator.string(from: date)
    }
}

// MARK: - Day separator

struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(ChatFormatters.daySeparator(date))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }
}

// MARK: - Status tick

struct MessageStatusIcon: View {
    let status: MessageStatus

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(Color(.tertiaryLabel))
        case .sent:
            Image(systemName: "checkmark")
                .foregroundStyle(Color(.tertiaryLabel))
        case .delivered:
            DoubleCheck().foregroundStyle(Color(.tertiaryLabel))
        case .read:
            DoubleCheck().foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// SF Symbols has no double checkmark, so two are overlapped by hand.
private struct DoubleCheck: View {
    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
            Image(systemName: "checkmark").offset(x: 5)
        }
        .padding(.trailing, 5)
    }
}

nonisolated func statusDescription(_ status: MessageStatus) -> String {
    switch status {
    case .pending:   return String(localized: "Sending")
    case .sent:      return String(localized: "Sent")
    case .delivered: return String(localized: "Delivered")
    case .read:      return String(localized: "Read")
    case .failed:    return String(localized: "Not sent")
    }
}

// MARK: - Reply preview

/// What a quoted reply shows: who wrote the original and a one-line snippet.
struct ReplyPreview: Equatable {
    let messageID: String
    let author: String
    let snippet: String
    let isImage: Bool
    /// The original isn't on this device (deleted, or sent before we joined).
    let isMissing: Bool
}

/// The quote block used inside a bubble and above the composer.
struct ReplyQuote: View {
    let preview: ReplyPreview
    var onDarkBubble = false

    private var accent: Color {
        onDarkBubble ? .white : AvatarView.color(for: preview.author)
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                if !preview.isMissing {
                    Text(preview.author)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
                Label {
                    Text(preview.snippet)
                        .lineLimit(2)
                } icon: {
                    if preview.isImage { Image(systemName: "photo") }
                }
                .labelStyle(ReplySnippetLabelStyle(showsIcon: preview.isImage))
                .font(.caption)
                .italic(preview.isMissing)
                .foregroundStyle(onDarkBubble ? Color.white.opacity(0.85) : .secondary)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ReplySnippetLabelStyle: LabelStyle {
    let showsIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if showsIcon { configuration.icon }
            configuration.title
        }
    }
}

// MARK: - Bubble

struct ChatMessageBubble: View {

    let message: StoredMessage
    /// Sender name shown above incoming bubbles in groups (nil in 1:1 chats).
    let senderName: String?
    /// Local file URL for an image message, resolved by the parent.
    let imageURL: URL?
    /// The message this one replies to, when it is a reply.
    var replyPreview: ReplyPreview? = nil
    /// Only the newest message in a thread shows its time under the bubble;
    /// the rest reveal theirs with a left swipe.
    var showsFooter = true
    /// The user tapped "Show original" on a translated message.
    var showsOriginal = false

    var onTapImage: (URL) -> Void = { _ in }
    var onRetry: () -> Void = {}
    var onTapReply: (String) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isMine: Bool { message.isFromMe }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isMine { Spacer(minLength: 48) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                if let senderName, !isMine {
                    Text(senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AvatarView.color(for: senderName))
                        .padding(.horizontal, 6)
                }

                VStack(alignment: .leading, spacing: 0) {
                    if let replyPreview, !message.isDeleted {
                        Button {
                            onTapReply(replyPreview.messageID)
                        } label: {
                            ReplyQuote(preview: replyPreview, onDarkBubble: isMine)
                                .padding(8)
                                .background(quoteFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(replyPreview.isMissing)
                        .padding(.horizontal, 6)
                        .padding(.top, 6)
                        .padding(.bottom, isPlainImage ? 6 : 0)
                    }

                    content
                        .padding(.horizontal, isPlainImage ? 0 : 14)
                        .padding(.vertical, isPlainImage ? 0 : 10)
                }
                .background(bubbleFill, in: BubbleShape(isFromMe: isMine))
                .clipShape(BubbleShape(isFromMe: isMine))

                if showsFooter || (isMine && message.status == .failed) {
                    footer
                }
            }

            if !isMine { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if message.isDeleted {
            Label {
                Text("This message was deleted")
            } icon: {
                Image(systemName: "trash.slash")
            }
            .font(.body.italic())
            .foregroundStyle(isMine ? Color.white.opacity(0.8) : .secondary)
            .fixedSize(horizontal: false, vertical: true)

        } else if message.kind == .image {
            imageContent

        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(displayedBody)
                    .font(.body)
                    .foregroundStyle(isMine ? Color.white : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                if message.translatedBody != nil {
                    Label {
                        Text(showsOriginal ? "Original" : "Translated")
                    } icon: {
                        Image(systemName: "character.bubble")
                    }
                    .font(.caption2)
                    .foregroundStyle(isMine ? Color.white.opacity(0.75) : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let imageURL {
            Button {
                onTapImage(imageURL)
            } label: {
                CachedFileImage(url: imageURL, maxPixel: 900)
                    .frame(maxWidth: 240, maxHeight: 300)
                    .frame(minWidth: 120, minHeight: 90)
                    .clipped()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Photo. Double tap to view full screen."))
        } else {
            Label {
                Text("Photo unavailable")
            } icon: {
                Image(systemName: "photo")
            }
            .font(.body)
            .foregroundStyle(isMine ? Color.white.opacity(0.85) : .secondary)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 5) {
            Text(ChatFormatters.time(message.timestamp))
                .font(.caption2)
                .foregroundStyle(Color(.tertiaryLabel))

            if isMine {
                MessageStatusIcon(status: message.status)
                    .font(.caption2)
            }

            if isMine, message.status == .failed {
                Button(action: onRetry) {
                    Text("Retry")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 6)
        .accessibilityHidden(true)
    }

    // MARK: Derivations

    private var isPlainImage: Bool {
        message.kind == .image && !message.isDeleted
    }

    private var quoteFill: Color {
        isMine ? Color.white.opacity(0.18) : Color(.systemGray4).opacity(0.6)
    }

    private var displayedBody: String {
        showsOriginal ? message.body : (message.translatedBody ?? message.body)
    }

    private var bubbleFill: Color {
        if message.isDeleted {
            return isMine ? Color.blue.opacity(0.55) : Color(.systemGray5)
        }
        return isMine ? .blue : Color(.systemGray5)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        parts.append(isMine ? String(localized: "You") : (senderName ?? String(localized: "Them")))
        if message.isDeleted {
            parts.append(String(localized: "This message was deleted"))
        } else if message.kind == .image {
            parts.append(String(localized: "Photo"))
        } else {
            parts.append(displayedBody)
            if message.translatedBody != nil { parts.append(String(localized: "Translated")) }
        }
        if let replyPreview, !message.isDeleted, !replyPreview.isMissing {
            parts.append(String(localized: "Reply to \(replyPreview.author): \(replyPreview.snippet)"))
        }
        parts.append(ChatFormatters.time(message.timestamp))
        if isMine { parts.append(statusDescription(message.status)) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Typing bubble

struct TypingBubble: View {
    let name: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color(.systemGray3))
                    .frame(width: 8, height: 8)
                    .offset(y: (animate && !reduceMotion) ? -4 : 4)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.45)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.systemGray5), in: BubbleShape(isFromMe: false))
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animate = true }
        .onDisappear { animate = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name.map { String(localized: "\($0) is typing") } ?? String(localized: "Typing")))
    }
}

// MARK: - Bubble shape

struct BubbleShape: Shape {
    let isFromMe: Bool
    var radius: CGFloat = 18

    nonisolated func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        let tail: CGFloat = min(4, r)
        let corners = RectangleCornerRadii(
            topLeading: isFromMe ? r : tail,
            bottomLeading: r,
            bottomTrailing: r,
            topTrailing: isFromMe ? tail : r
        )
        return Path(roundedRect: rect, cornerRadii: corners, style: .continuous)
    }
}

// MARK: - Full-screen image viewer

struct FullScreenImageViewer: View {

    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var saveState: SaveState = .idle

    private enum SaveState: Equatable {
        case idle, saving, saved, failed(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                CachedFileImage(url: url, maxPixel: 2400)
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel(Text("Photo"))
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Close"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saveState == .saving {
                            ProgressView()
                        } else {
                            Image(systemName: saveState == .saved
                                  ? "checkmark.circle.fill"
                                  : "square.and.arrow.down")
                        }
                    }
                    .disabled(saveState == .saving || saveState == .saved)
                    .accessibilityLabel(Text("Save to Photos"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if case .failed(let message) = saveState {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.red.opacity(0.85))
                }
            }
        }
    }

    private func save() async {
        saveState = .saving
        let result = await PhotoSaver.save(fileURL: url)
        switch result {
        case .success:
            saveState = .saved
        case .failure(let message):
            Log.ui.error("Saving a photo failed: \(message, privacy: .public)")
            saveState = .failed(message)
        }
    }
}
