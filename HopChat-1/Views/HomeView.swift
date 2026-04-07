//
//  KeychainHelper.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 26/02/2026.
//


import SwiftUI
 
// MARK: - Chat List

struct ChatListView: View {
   @StateObject private var store = ConversationStore.shared
   @StateObject private var kad   = KademliaService.shared
   @State private var searchText  = ""
   @State private var selectedTab = 0
   @State private var showNewChat = false

   var body: some View {
       NavigationStack {
           VStack(spacing: 0) {

               // MARK: Header
               HStack {
                   Image(systemName: "wifi")
                       .font(.system(size: 25))
                       .foregroundStyle(.blue)
                   Text("Messages")
                       .font(.system(size: 28, weight: .bold))
                   Spacer()
                   Button { showNewChat = true } label: {
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


               // MARK: Search
               HStack(spacing: 12) {
                   Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                   TextField("Search", text: $searchText).font(.system(size: 16))
               }
               .padding(.horizontal, 14)
               .padding(.vertical, 10)
               .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
               .padding(.horizontal, 20)
               .padding(.bottom, 8)

               // MARK: Conversation List
               if filteredContacts.isEmpty {
                   Spacer()
                   VStack(spacing: 12) {
                       Image(systemName: "bubble.left.and.bubble.right")
                           .font(.system(size: 48))
                           .foregroundStyle(.secondary)
                       Text("No conversations yet")
                           .font(.headline)
                           .foregroundStyle(.secondary)
                       Button("Start a Chat") { showNewChat = true }
                           .buttonStyle(.borderedProminent)
                   }
                   Spacer()
               } else {
                   ScrollView {
                       LazyVStack(spacing: 0) {
                           ForEach(filteredContacts) { contact in
                               NavigationLink {
                                   TextRoomView(contact: contact, myPhone: kad.myPhone)
                               } label: {
                                   ChatRowView(contact: contact, myPhone: kad.myPhone)
                               }
                               .buttonStyle(.plain)
                               Divider().padding(.leading, 78)
                           }
                       }
                   }
               }

               Spacer()

               // MARK: Tab Bar
               Divider()
               HStack {
                   TabBarItem(icon: "bubble.left",  label: "CHATS",    isSelected: selectedTab == 0) { selectedTab = 0 }
                   TabBarItem(icon: "person",        label: "PEOPLE",   isSelected: selectedTab == 1) { selectedTab = 1 }
                   TabBarItem(icon: "gearshape",     label: "SETTINGS", isSelected: selectedTab == 2) { selectedTab = 2 }
               }
               .padding(.horizontal, 20)
               .padding(.vertical, 12)
           }
           .background(Color(.systemBackground))
           .sheet(isPresented: $showNewChat) {
               NewChatSheet()
           }
           // Listen for incoming contact requests
           .onReceive(NotificationCenter.default.publisher(for: .newContactRequest)) { note in
               guard let phone = note.userInfo?["phone"] as? String,
                     let ip    = note.userInfo?["ip"]    as? String,
                     let port  = note.userInfo?["port"]  as? UInt16 else { return }
               let contact = Contact(phone: phone, name: phone, ip: ip, port: port, addedAt: Date())
               ConversationStore.shared.addContact(contact)
           }
           .navigationDestination(isPresented: Binding(
               get: { selectedTab == 1 },
               set: { if !$0 { selectedTab = 0 } }
           )) {
               PeopleView().navigationBarBackButtonHidden(true)
           }
           .navigationDestination(isPresented: Binding(
               get: { selectedTab == 2 },
               set: { if !$0 { selectedTab = 0 } }
           )) {
               SettingsView().navigationBarBackButtonHidden(true)
           }
       }
   }

   private var filteredContacts: [Contact] {
       let all = store.contacts
       if searchText.isEmpty { return all }
       return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) ||
                           $0.phone.contains(searchText) }
   }

   private func initials(for name: String) -> String {
       name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
   }
}

// MARK: - Chat Row

struct ChatRowView: View {
   let contact: Contact
   let myPhone: String

   private var last: StoredMessage? {
       ConversationStore.shared.lastMessage(with: contact.phone, myPhone: myPhone)
   }

   var body: some View {
       HStack(spacing: 14) {
           // Avatar
           ZStack {
               Circle().fill(Color(.systemGray4)).frame(width: 52, height: 52)
               Text(initials).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
           }

           VStack(alignment: .leading, spacing: 3) {
               Text(contact.name)
                   .font(.system(size: 16, weight: .semibold))
               Text(last?.body ?? "No messages yet")
                   .font(.system(size: 14))
                   .foregroundStyle(.secondary)
                   .lineLimit(1)
           }

           Spacer()

           if let last {
               Text(timeString(last.timestamp))
                   .font(.system(size: 13))
                   .foregroundStyle(.secondary)
           }
       }
       .padding(.horizontal, 20)
       .padding(.vertical, 12)
   }

   private var initials: String {
       contact.name.split(separator: " ").prefix(2)
           .compactMap { $0.first }.map(String.init).joined()
           .isEmpty ? String(contact.name.prefix(2)).uppercased() : ""
   }

   private func timeString(_ date: Date) -> String {
       let cal = Calendar.current
       if cal.isDateInToday(date) {
           let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
       } else if cal.isDateInYesterday(date) {
           return "Yesterday"
       } else {
           let f = DateFormatter(); f.dateStyle = .short; return f.string(from: date)
       }
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
               Image(systemName: icon).font(.system(size: 22))
               Text(label).font(.system(size: 10, weight: .medium))
           }
           .foregroundStyle(isSelected ? .blue : .secondary)
           .frame(maxWidth: .infinity)
       }
   }
}

// MARK: - New Chat Sheet

struct NewChatSheet: View {
   @Environment(\.dismiss) private var dismiss
   @StateObject private var kad = KademliaService.shared
   @State private var phone     = ""
   @State private var name      = ""
   @State private var isLoading = false
   @State private var error: String?

   var body: some View {
       NavigationStack {
           Form {
               Section("Contact") {
                   TextField("Phone number", text: $phone)
                       .keyboardType(.phonePad)
                   TextField("Display name (optional)", text: $name)
               }

               if let error {
                   Section {
                       Text(error).foregroundStyle(.red)
                   }
               }

               Section {
                   Button {
                       guard !phone.isEmpty else { return }
                       isLoading = true
                       error = nil
                       Task {
                           let ok = await kad.connectTo(phone: phone)
                           isLoading = false
                           if ok {
                               // Update display name if provided
                               if !name.isEmpty, let idx = ConversationStore.shared.contacts.firstIndex(where: { $0.phone == phone }) {
                                   // We'd need a mutating method here — simple workaround:
                                   let c = ConversationStore.shared.contacts[idx]
                                   let updated = Contact(phone: c.phone, name: name, ip: c.ip, port: c.port, addedAt: c.addedAt)
                                   ConversationStore.shared.addContact(updated)
                               }
                               dismiss()
                           } else {
                               error = "Could not reach \(phone). Make sure they're on the same WiFi and have HopChat open."
                           }
                       }
                   } label: {
                       if isLoading {
                           HStack { Spacer(); ProgressView(); Spacer() }
                       } else {
                           Text("Connect")
                       }
                   }
                   .disabled(phone.isEmpty || isLoading)
               }
           }
           .navigationTitle("New Chat")
           .navigationBarTitleDisplayMode(.inline)
           .toolbar {
               ToolbarItem(placement: .cancellationAction) {
                   Button("Cancel") { dismiss() }
               }
           }
       }
   }
}

#Preview {
   ChatListView()
}

