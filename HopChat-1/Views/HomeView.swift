//
//  KeychainHelper.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 26/02/2026.
//


import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let name: String
    let preview: String
    let time: String
    let isUnread: Bool
    let isGroup: Bool
    let imageName: String?
    let sentBy: String
}

struct ChatListView: View {
    @State private var searchText = ""
    @State private var selectedTab = 0

    let chats: [ChatMessage] = [
        ChatMessage(name: "Alex Johnson", preview: "Hey, are we still meeting today?", time: "2:45 PM", isUnread: false, isGroup: false, imageName: nil, sentBy: "b2eee3a1-9c61-4a82-9f54-6f3bceed8aa6"),
        ChatMessage(name: "Design Team", preview: "Sarah: The new mocks are ready for...", time: "1:12 PM", isUnread: true, isGroup: true, imageName: nil, sentBy: "53f2f0ab-1e71-41b0-a6e0-4470e44a5a60"),
        ChatMessage(name: "Emma Wilson", preview: "That sounds like a great plan!", time: "Yesterday", isUnread: false, isGroup: false, imageName: nil, sentBy:"06a06dea-9c8a-4e84-acaa-db0962046d0b"),
        ChatMessage(name: "Michael Chen", preview: "Can you send over the file from earlier?", time: "Tuesday", isUnread: false, isGroup: false, imageName: nil, sentBy: "e8b49fe7-a84b-43b4-be36-332f4f5907f4"),
        ChatMessage(name: "Sophie Taylor", preview: "I'll check with the manager and get back...", time: "Monday", isUnread: false, isGroup: false, imageName: nil, sentBy: "d8b83790-459d-4483-ad6c-8571932750f4"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // MARK: Header
                HStack {
                    Image(systemName: "wifi")
                        .font(.system(size: 25))
                        .foregroundStyle(.blue)
                        .shadow(color: .blue.opacity(0.4), radius: 20, x: 0, y: 10)
                    Text("Messages")
                        .font(.system(size: 28, weight: .bold))
                    Spacer()
                    Button(action: {}) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 18))
                            .foregroundStyle(.blue)
                            .padding(10)
                            .background(Color(.systemGray6), in: Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // MARK: Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .font(.system(size: 16))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                // MARK: Chat List
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chats) { chat in
                            NavigationLink(destination: TextRoomView(
                                userName: chat.name,
                                userInitials: initials(for: chat.name),
                                messages: [ChatMessage2(
                                    text: chat.preview,
                                    isFromMe: false,
                                    time: chat.time
                                )]
                            )) {
                                ChatRowView(chat: chat)
                            }
                            .buttonStyle(.plain)
                            Divider()
                                .padding(.leading, 78)
                        }
                    }
                }

                Spacer()

                // MARK: Tab Bar
                Divider()
                HStack {
                    TabBarItem(icon: "bubble.left", label: "CHATS", isSelected: selectedTab == 0) { selectedTab = 0 }
                    TabBarItem(icon: "person", label: "PEOPLE", isSelected: selectedTab == 1) { selectedTab = 1 }
                    TabBarItem(icon: "gearshape", label: "SETTINGS", isSelected: selectedTab == 2) { selectedTab = 2 }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color(.systemBackground))
        }
    }

    // Helper: "Alex Johnson" → "AJ"
    private func initials(for name: String) -> String {
        name.split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0) }
            .joined()
    }
}

// MARK: - Chat Row
struct ChatRowView: View {
    let chat: ChatMessage

    var body: some View {
        HStack(spacing: 14) {
            // Avatar
            ZStack {
                if chat.isGroup {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                } else {
                    Circle()
                        .fill(Color(.systemGray4))
                        .frame(width: 52, height: 52)
                    Image(systemName: "person.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                }
            }

            // Text
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.name)
                    .font(.system(size: 16, weight: .semibold))
                Text(chat.preview)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(chat.time)
                    .font(.system(size: 13))
                    .foregroundStyle(chat.isUnread ? .blue : .secondary)
                if chat.isUnread {
                    Circle()
                        .fill(.blue)
                        .frame(width: 10, height: 10)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Tab Bar Item
struct TabBarItem: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isSelected ? .blue : .secondary)
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    ChatListView()
}
