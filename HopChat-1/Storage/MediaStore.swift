//
//  MediaStore.swift
//  HopChat-1
//
//  Images and avatars live as individual protected files, never inside the JSON
//  thread files. Avatars are named by SHA-256 of the phone so no phone number
//  ever appears in a filename.
//

import Foundation
import CryptoKit
import os

nonisolated struct MediaStore: Sendable {

    let mediaDirectory: URL
    let avatarsDirectory: URL

    private var fm: FileManager { .default }

    init(root: URL) {
        self.mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        self.avatarsDirectory = root.appendingPathComponent("avatars", isDirectory: true)
    }

    // MARK: - Hashing

    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Directories

    func ensureDirectories() {
        for dir in [mediaDirectory, avatarsDirectory] {
            guard !fm.fileExists(atPath: dir.path) else { continue }
            do {
                try fm.createDirectory(at: dir,
                                       withIntermediateDirectories: true,
                                       attributes: StorageProtection.directoryAttributes)
            } catch {
                Log.store.error("could not create media directory: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Message images

    /// Writes `data` as `media/<id>.jpg` and returns the filename.
    @discardableResult
    func saveImage(_ data: Data, id: String) throws -> String {
        ensureDirectories()
        let filename = "\(id).jpg"
        try data.write(to: mediaDirectory.appendingPathComponent(filename),
                       options: StorageProtection.writingOptions)
        return filename
    }

    func imageURL(_ filename: String) -> URL {
        mediaDirectory.appendingPathComponent(filename)
    }

    func deleteImage(_ filename: String?) {
        guard let filename, !filename.isEmpty else { return }
        try? fm.removeItem(at: imageURL(filename))
    }

    // MARK: - Avatars

    /// Writes an avatar JPEG named by SHA-256 of the phone; returns the filename.
    @discardableResult
    func saveAvatar(_ data: Data, phone: String) throws -> String {
        ensureDirectories()
        let filename = "\(MediaStore.sha256Hex(phone)).jpg"
        try data.write(to: avatarsDirectory.appendingPathComponent(filename),
                       options: StorageProtection.writingOptions)
        return filename
    }

    func avatarURL(_ filename: String) -> URL {
        avatarsDirectory.appendingPathComponent(filename)
    }

    func deleteAvatar(_ filename: String?) {
        guard let filename, !filename.isEmpty else { return }
        try? fm.removeItem(at: avatarURL(filename))
    }
}
