//
//  KeychainHelper.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 26/02/2026.
//

import SwiftUI

struct ChatMessage2: Identifiable {
    let id = UUID()
    let text: String
    let isFromMe: Bool
    let time: String
    var status: String? = nil
    var isTyping: Bool = false
}

struct TextRoomView: View {
    let userName: String
    let userInitials: String

    @State var messages: [ChatMessage2]
    @State private var messageText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // MARK: Header (optional date separator)
                Divider()
                
                // MARK: Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            // Date header
                            Text("TODAY 10:42 AM")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 16)
                            
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                if message.isTyping {
                                    TypingBubble()
                                } else {
                                    MessageBubble(message: message, index: index)
                                        .id(message.id)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: messages.count) { _, new in
                        if let last = messages.last {
                            withAnimation(.easeInOut) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                
                Divider()
                
                // MARK: Input Bar
                HStack(spacing: 12) {
                    Button(action: {}) {
                        Image(systemName: "plus")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    
                    TextField("HopChat Message", text: $messageText)
                        .font(.system(size: 16))
                        .focused($isFocused)
                    
                    if !messageText.isEmpty {
                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.blue, in: Circle())
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(.systemGray6), in: Capsule())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(Color(.systemBackground))
            .toolbar {
            
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 4) {
                        Circle()
                            .fill(Color(.systemGray4))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(userInitials)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                            )
                        Text(userName.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.primary)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let msg = ChatMessage2(text: messageText, isFromMe: true, time: "Now", status: "DELIVERED")
        messages.append(msg)
        messageText = ""
    }
}

// MARK: - Message Bubble
struct MessageBubble: View {
    let message: ChatMessage2
    let index: Int  // NEW: For staggered animation
    
    @Namespace private var animation  // NEW: Matched geometry
    
    @State private var opacity: Double = 0
    @State private var offsetY: CGFloat = 50
    
    var body: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
            HStack {
                if message.isFromMe { Spacer(minLength: 60) }
                
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.isFromMe ? Color.blue : Color(.systemGray5),
                        in: BubbleShape(isFromMe: message.isFromMe)
                    )
                    .opacity(opacity)
                    .offset(y: offsetY)
                    .matchedGeometryEffect(id: "bubble-\(message.id)", in: animation)
                    .onAppear {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(index) * 0.1)) {
                            opacity = 1
                            offsetY = 0
                        }
                    }
                
                if !message.isFromMe { Spacer(minLength: 60) }
            }
            
            // Status (unchanged)
            if let status = message.status {
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .animation(.spring(), value: opacity)
    }
}

// MARK: - Typing Bubble
struct TypingBubble: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(.systemGray3))
                    .frame(width: 8, height: 8)
                    .scaleEffect(animate ? 1.2 : 0.8)
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever()
                        .delay(Double(i) * 0.15),
                        value: animate
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.systemGray5), in: BubbleShape(isFromMe: false))
        .padding(.leading, 16)
        .onAppear { animate = true }
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

            // Corner radii: [topLeft, topRight, bottomRight, bottomLeft]
            let tl: CGFloat = isFromMe ? r : 4
            let tr: CGFloat = isFromMe ? 4 : r
            let br: CGFloat = isFromMe ? r : r
            let bl: CGFloat = isFromMe ? r : r

            var path = Path()
            path.move(to: CGPoint(x: tl, y: 0))
            path.addLine(to: CGPoint(x: w - tr, y: 0))
            path.addArc(center: CGPoint(x: w - tr, y: tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: w, y: h - br))
            path.addArc(center: CGPoint(x: w - br, y: h - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: bl, y: h))
            path.addArc(center: CGPoint(x: bl, y: h - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: 0, y: tl))
            path.addArc(center: CGPoint(x: tl, y: tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            path.closeSubpath()
            return path
        }
}

#Preview {
    TextRoomView(
        userName: "Alex Rivera",
        userInitials: "AR",
        messages: [
            ChatMessage2(text: "Hey! Did you see the new update for HopChat?", isFromMe: false, time: "10:42 AM"),
            ChatMessage2(text: "Not yet, let me check it out now. Is it the one with the new themes?", isFromMe: true, time: "10:43 AM"),
            ChatMessage2(text: "Exactly! They added a bunch of modern themes.", isFromMe: false, time: "10:44 AM"),
            ChatMessage2(text: "The dark mode looks incredible.", isFromMe: false, time: "10:44 AM"),
            ChatMessage2(text: "I'm switching to it right now. Thanks for the heads up! 🚀", isFromMe: true, time: "10:45 AM", status: "DELIVERED"),
            ChatMessage2(text: "", isFromMe: false, time: "", isTyping: true),
        ]
    )
}
