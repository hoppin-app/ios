//
//  DemoContent.swift
//  HopChat-1
//
//  App Store screenshots only. Launching a DEBUG build with `-hoppinDemo`
//  fills the store with made-up contacts and chats. The numbers are in
//  Ofcom's drama range (+44 7700 900xxx), so none of them is a real person,
//  and none has keys: nothing here is ever sent anywhere.
//
//  Contacts are added once (the store ignores duplicates); the demo chats
//  are deleted and rebuilt on each launch, so nothing doubles up.
//

#if DEBUG
import Foundation

@MainActor
enum DemoContent {

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-hoppinDemo")
    }

    private static let maya  = "+447700900101"
    private static let tom   = "+447700900102"
    private static let ines  = "+447700900103"
    private static let sam   = "+447700900104"
    private static let priya = "+447700900105"
    private static let alex  = "+447700900106"
    private static let groupID = "demo-group-lisbon"

    /// Maya is "on the same Wi-Fi", so her chat reads as a live direct link.
    static func presence(for phone: String) -> PresenceStatus? {
        guard isRequested else { return nil }
        return phone == maya ? .online : .offline
    }

    /// Seeds once the account exists, so `me` is the signed-in number.
    static func seedIfRequested(store: ConversationStore, me: String) {
        guard isRequested, !me.isEmpty else { return }

        // Opening a seeded chat must not try to send receipts to made-up numbers.
        UserDefaults.standard.set(false, forKey: AppConfig.Keys.sendReadReceipts)
        UserDefaults.standard.set(false, forKey: AppConfig.Keys.sendTypingIndicators)

        let now = Date()
        // Message times count back from 09:41 today, the status-bar time.
        let anchor = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: now) ?? now
        func ago(_ minutes: Double) -> Date { anchor.addingTimeInterval(-minutes * 60) }

        for (phone, name, days) in [(maya, "Maya Thompson", 40.0), (tom, "Tom Brennan", 30),
                                    (ines, "Inês Duarte", 25), (sam, "Sam Okafor", 20),
                                    (priya, "Priya Nair", 12), (alex, "Alex Moreau", 6)] {
            store.addContact(Contact(phone: phone, name: name,
                                     addedAt: now.addingTimeInterval(-days * 86_400)))
        }

        store.upsertGroup(ChatGroup(id: groupID, name: "Lisbon trip 🇵🇹",
                                    members: [me, maya, tom, ines],
                                    admins: [me],
                                    createdAt: now.addingTimeInterval(-9 * 86_400)))

        // Rebuilt on every launch, so edits to the script below always show.
        let lisbon = ConversationStore.conversationID(group: groupID)
        for conversationID in [maya, tom, ines, sam, priya, alex, lisbon] {
            store.deleteConversation(conversationID)
        }

        var n = 0
        func add(_ conversationID: String, from sender: String?, _ body: String,
                 _ minutesAgo: Double, route: MessageRoute = .relay,
                 status: MessageStatus = .read, unread: Bool = false) {
            n += 1
            let mine = sender == nil
            store.appendMessage(StoredMessage(
                id: "demo-\(n)",
                conversationID: conversationID,
                fromPhone: sender ?? me,
                toPhone: mine ? conversationID : me,
                body: body,
                timestamp: ago(minutesAgo),
                status: mine ? status : .read,
                isFromMe: mine,
                isRead: !unread,
                route: route))
        }

        // Same Wi-Fi: every message went phone to phone.
        add(maya, from: maya, "Are you at the café already?", 14, route: .direct)
        add(maya, from: nil, "Just sat down, table by the window", 13, route: .direct)
        add(maya, from: maya, "Perfect, 5 min ☕️", 12, route: .direct)
        add(maya, from: nil, "Flat white for you?", 11, route: .direct)
        add(maya, from: maya, "Yes please! Oat milk 🙏", 10, route: .direct)
        add(maya, from: nil, "Ordered. This came straight from my phone to yours — no server in between", 9, route: .direct)

        // No signal at all: hop by hop over Bluetooth. Delivered, so nothing
        // waits to be re-sent through the relay.
        add(tom, from: tom, "Zero signal up here 🏔️", 95, route: .mesh)
        add(tom, from: nil, "Same. Still getting your messages though", 93, route: .mesh, status: .delivered)
        add(tom, from: tom, "Bluetooth through the other phones on the trail apparently", 91, route: .mesh)
        add(tom, from: nil, "Meet at the hut at 3?", 90, route: .mesh, status: .delivered)
        add(tom, from: tom, "Deal. I'll bring the stove 🔥", 88, route: .mesh)

        add(lisbon, from: ines, "Flights booked! Landing Friday 10:40 ✈️", 180)
        add(lisbon, from: maya, "Amazing 🎉 who's sorting the flat?", 175)
        add(lisbon, from: nil, "Me — sending options tonight", 170)
        add(lisbon, from: tom, "Somewhere near Alfama please", 160)
        add(lisbon, from: ines, "And we're doing pastéis de nata on day one, non-negotiable", 150)
        add(lisbon, from: nil, "Obviously 😄", 148)

        add(sam, from: nil, "Good luck with the presentation today", 300)
        add(sam, from: sam, "Thanks! Went really well 🙌", 40, unread: true)
        add(sam, from: sam, "Drinks on Friday to celebrate?", 39, unread: true)

        add(priya, from: priya, "Here's the recipe I promised", 1_500)
        add(priya, from: nil, "You're the best, trying it this weekend", 1_490, status: .read)

        add(alex, from: nil, "Happy birthday!! 🎂", 4_400)
        add(alex, from: alex, "Thank you 😊", 4_380)
    }
}
#endif
