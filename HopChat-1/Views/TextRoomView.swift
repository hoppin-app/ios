//
//  KeychainHelper.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 26/02/2026.
//
//
//  TextRoomView.swift
//  HopChat-1
//
//  Live chat room. Messages come in via NotificationCenter (from KademliaProtocol)
//  and are persisted/read from ConversationStore.
//

import SwiftUI

struct TextRoomView: View {
    let contact:  Contact
    let myPhone:  String

    @StateObject private var store = ConversationStore.shared
    @StateObject private var kad   = KademliaService.shared
    @State private var messageText    = ""
    @State private var isSending      = false
    @State private var lastTypingSent = Date.distantPast  // throttle typing indicators
    @FocusState private var isFocused: Bool

    private var isContactTyping: Bool {
        kad.typingPeers.contains(contact.phone)
    }

    private var messages: [StoredMessage] {
        store.thread(with: contact.phone, myPhone: myPhone)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            if let error = kad.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            // MARK: Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if messages.isEmpty {
                            Text("No messages yet.\nSay hello! 👋")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 60)
                        }
                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                        if isContactTyping {
                            TypingBubble()
                                .id("typing")
                                .transition(.scale(scale: 0.85, anchor: .bottomLeading)
                                    .combined(with: .opacity))
                        }
                    }
                    .padding(.bottom, 8)
                    .padding(.top, 16)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation(.easeInOut) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: isContactTyping) { _, typing in
                    if typing {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            proxy.scrollTo("typing", anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // MARK: Input Bar
            HStack(spacing: 12) {
                TextField("Message", text: $messageText, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(5)
                    .focused($isFocused)

                if !messageText.isEmpty {
                    Button(action: sendMessage) {
                        if isSending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(8)
                    .background(.blue, in: Circle())
                    .disabled(isSending)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    ZStack {
                        Circle().fill(Color(.systemGray4)).frame(width: 34, height: 34)
                        Text(avatarInitials).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    }
                    Text(contact.name.uppercased()).font(.system(size: 10, weight: .semibold))
                }
            }
        }
        // Mark all messages as read whenever this view is visible or receives new ones
        .onAppear {
            store.markThreadRead(with: contact.phone, myPhone: myPhone)
        }
        .onReceive(NotificationCenter.default.publisher(for: .incomingChatMessage)) { _ in
            store.markThreadRead(with: contact.phone, myPhone: myPhone)
        }
        // Send typing indicator — at most once every 1.5 s while the user is typing
        .onChange(of: messageText) { _, newValue in
            guard !newValue.isEmpty else { return }
            let now = Date()
            guard now.timeIntervalSince(lastTypingSent) >= 1.5 else { return }
            lastTypingSent = now
            kad.sendTypingIndicator(toPhone: contact.phone)
        }
    }

    // MARK: - Send

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messageText = ""
        isSending   = true

        Task {
            await kad.send(body: text, toPhone: contact.phone)
            isSending = false
        }
    }

    private var avatarInitials: String {
        let parts = contact.name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init)
        return parts.isEmpty ? String(contact.name.prefix(2)).uppercased() : parts.joined()
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: StoredMessage

    @State private var opacity:  Double  = 0
    @State private var offsetY:  CGFloat = 20

    private var timeString: String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: message.timestamp)
    }

    var body: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
            HStack {
                if message.isFromMe { Spacer(minLength: 60) }

                VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                    Text(message.translatedBody ?? message.body)
                        .font(.system(size: 16))
                        .foregroundStyle(message.isFromMe ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(message.isFromMe ? Color.blue : Color(.systemGray5),
                                    in: BubbleShape(isFromMe: message.isFromMe))

                    if message.translatedBody != nil {
                        Label("Translated", systemImage: "character.bubble")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(opacity)
                .offset(y: offsetY)
                .onAppear {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        opacity = 1; offsetY = 0
                    }
                }

                if !message.isFromMe { Spacer(minLength: 60) }
            }

            HStack(spacing: 4) {
                if message.isFromMe { Spacer() }
                Text(timeString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if message.isFromMe {
                    Image(systemName: message.delivered ? "checkmark.circle.fill" : "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(message.delivered ? .blue : .secondary)
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Typing Bubble

struct TypingBubble: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(.systemGray3))
                    .frame(width: 8, height: 8)
                    .offset(y: animate ? -4 : 4)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: animate
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.systemGray5), in: BubbleShape(isFromMe: false))
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animate = true }
        .onDisappear { animate = false }
    }
}

// MARK: - Bubble Shape

struct BubbleShape: Shape {
    let isFromMe: Bool
    let radius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let r = radius
        let w = rect.width
        let h = rect.height
        let tl: CGFloat = isFromMe ? r : 4
        let tr: CGFloat = isFromMe ? 4 : r
        let br: CGFloat = r
        let bl: CGFloat = r

        var path = Path()
        path.move(to: CGPoint(x: tl, y: 0))
        path.addLine(to: CGPoint(x: w - tr, y: 0))
        path.addArc(center: CGPoint(x: w - tr, y: tr), radius: tr,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: w, y: h - br))
        path.addArc(center: CGPoint(x: w - br, y: h - br), radius: br,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: bl, y: h))
        path.addArc(center: CGPoint(x: bl, y: h - bl), radius: bl,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: 0, y: tl))
        path.addArc(center: CGPoint(x: tl, y: tl), radius: tl,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

#Preview {
    NavigationStack {
        TextRoomView(
            contact: Contact(phone: "+351912345678", name: "Alex Rivera",
                             ip: "192.168.1.5", port: 4001, addedAt: Date()),
            myPhone: "+351987654321"
        )
    }
}
