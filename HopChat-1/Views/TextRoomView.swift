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
    @State private var messageText = ""
    @State private var isSending   = false
    @FocusState private var isFocused: Bool

    private var messages: [StoredMessage] {
        store.thread(with: contact.phone, myPhone: myPhone)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                    }
                    .padding(.bottom, 8)
                    .padding(.top, 16)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation(.easeInOut) { proxy.scrollTo(last.id, anchor: .bottom) }
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
                TextField("HopChat Message", text: $messageText, axis: .vertical)
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
        // Listen for messages arriving while this view is open
        .onReceive(NotificationCenter.default.publisher(for: .incomingChatMessage)) { note in
            // ConversationStore already updated; SwiftUI re-renders via @StateObject
            _ = note  // nothing extra to do
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

                Text(message.body)
                    .font(.system(size: 16))
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(message.isFromMe ? Color.blue : Color(.systemGray5),
                                in: BubbleShape(isFromMe: message.isFromMe))
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
