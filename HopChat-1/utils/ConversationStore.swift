//
//  ConversationStore.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 04/04/2026.
//

import Foundation
import Combine

// MARK: - Models

struct Contact: Identifiable, Codable, Hashable {
    var id:    String { phone }
    let phone: String
    var name:  String     // user-provided display name (defaults to phone)
    var ip:    String
    var port:  UInt16
    var addedAt: Date
}

struct StoredMessage: Identifiable, Codable {
    let id:         String   // chatID (stable UUID)
    let fromPhone:  String   // sender phone
    let toPhone:    String   // recipient phone
    let body:       String
    let timestamp:  Date
    var delivered:  Bool
    var isFromMe:   Bool
}

// MARK: - Store

@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var contacts: [Contact] = []
    /// phone → sorted messages
    @Published private(set) var messages: [String: [StoredMessage]] = [:]

    private let contactsKey = "hopchat.contacts.v1"
    private let messagesKey = "hopchat.messages.v1"

    private init() { load() }

    // MARK: - Contacts

    func addContact(_ contact: Contact) {
        if !contacts.contains(where: { $0.phone == contact.phone }) {
            contacts.append(contact)
            save()
        }
    }

    func updateContact(phone: String, ip: String, port: UInt16) {
        if let idx = contacts.firstIndex(where: { $0.phone == phone }) {
            contacts[idx] = Contact(phone: phone, name: contacts[idx].name,
                                    ip: ip, port: port, addedAt: contacts[idx].addedAt)
            save()
        }
    }

    func contact(for phone: String) -> Contact? {
        contacts.first { $0.phone == phone }
    }

    // MARK: - Messages

    func appendMessage(_ msg: StoredMessage) {
        let key = conversationKey(msg)
        var thread = messages[key] ?? []
        // Dedup by id
        guard !thread.contains(where: { $0.id == msg.id }) else { return }
        thread.append(msg)
        thread.sort { $0.timestamp < $1.timestamp }
        messages[key] = thread
        save()
    }

    func markDelivered(chatID: String, peerPhone: String, myPhone: String) {
        let key = threadKey(phone1: myPhone, phone2: peerPhone)
        guard var thread = messages[key],
              let idx = thread.firstIndex(where: { $0.id == chatID }) else { return }
        thread[idx].delivered = true
        messages[key] = thread
        save()
    }

    func thread(with peerPhone: String, myPhone: String) -> [StoredMessage] {
        messages[threadKey(phone1: myPhone, phone2: peerPhone)] ?? []
    }

    func lastMessage(with peerPhone: String, myPhone: String) -> StoredMessage? {
        thread(with: peerPhone, myPhone: myPhone).last
    }

    // MARK: - Persistence

    private func conversationKey(_ msg: StoredMessage) -> String {
        threadKey(phone1: msg.fromPhone, phone2: msg.toPhone)
    }

    /// Canonical key: always sort the two phones so both sides use the same bucket.
    private func threadKey(phone1: String, phone2: String) -> String {
        [phone1, phone2].sorted().joined(separator: "↔︎")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(contacts) {
            UserDefaults.standard.set(data, forKey: contactsKey)
        }
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: messagesKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: contactsKey),
           let c = try? JSONDecoder().decode([Contact].self, from: data) {
            contacts = c
        }
        if let data = UserDefaults.standard.data(forKey: messagesKey),
           let m = try? JSONDecoder().decode([String: [StoredMessage]].self, from: data) {
            messages = m
        }
    }
}
