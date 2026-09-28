//
//  AppearanceTests.swift
//  HopChat-1Tests
//
//  Bubble colours (what is stored, and text that stays readable on any of
//  them) and background drawings (kept as files, back in the order they were
//  made, gone with their files).
//

import Testing
import Foundation
import PencilKit
@testable import HopChat_1

@Suite("BubbleColor")
struct BubbleColorTests {

    @Test("empty or unreadable falls back to the violet")
    func fallback() {
        #expect(BubbleColor.hex(from: "") == BubbleColor.defaultHex)
        #expect(BubbleColor.hex(from: "not a colour") == BubbleColor.defaultHex)
        #expect(BubbleColor.hex(from: "1f6feb") == "#1F6FEB")
    }

    @Test("text is white on dark colours and ink on light ones")
    func legibleText() {
        #expect(!BubbleColor.prefersDarkText(BubbleColor.defaultHex))
        #expect(!BubbleColor.prefersDarkText("#3A3A45"))
        #expect(BubbleColor.prefersDarkText("#AB9CFF"))
        #expect(BubbleColor.prefersDarkText("#FFD43B"))
    }

    @Test("every preset reads back as itself")
    func presets() {
        for preset in BubbleColor.presets {
            #expect(BubbleColor.hex(from: preset.hex) == preset.hex)
        }
    }
}

@MainActor
@Suite("BackgroundDrawings")
struct BackgroundDrawingsTests {

    @Test("drawings are kept as files and come back in the order they were made")
    func persistence() {
        let temp = TempDirectory()
        let directory = temp.url.appendingPathComponent("drawings", isDirectory: true)
        let drawings = BackgroundDrawings(directory: directory)
        #expect(drawings.add(PKDrawing()))
        #expect(drawings.add(PKDrawing()))
        #expect(drawings.add(PKDrawing()))
        let ids = drawings.items.map(\.id)

        #expect(BackgroundDrawings(directory: directory).items.map(\.id) == ids)

        drawings.remove(id: ids[1])
        #expect(BackgroundDrawings(directory: directory).items.map(\.id) == [ids[0], ids[2]])
    }

    @Test("no more than the limit")
    func limit() {
        let temp = TempDirectory()
        let drawings = BackgroundDrawings(directory: temp.url.appendingPathComponent("drawings", isDirectory: true))
        for _ in 0..<BackgroundDrawings.limit {
            drawings.add(PKDrawing())
        }
        #expect(!drawings.canAdd)
        #expect(!drawings.add(PKDrawing()))
        #expect(drawings.items.count == BackgroundDrawings.limit)
    }

    @Test("removeAll leaves nothing to load")
    func removeAll() {
        let temp = TempDirectory()
        let directory = temp.url.appendingPathComponent("drawings", isDirectory: true)
        let drawings = BackgroundDrawings(directory: directory)
        drawings.add(PKDrawing())
        drawings.removeAll()
        #expect(drawings.items.isEmpty)
        #expect(BackgroundDrawings(directory: directory).items.isEmpty)
    }
}
