//
//  Command.swift
//
//  Created by Sunny Young.
//

import Foundation
import ArgumentParser

struct Command {
    enum Error: @unchecked Sendable, LocalizedError {
        case executing(command: String, error: NSDictionary)

        var errorDescription: String? {
            switch self {
            case let .executing(command, error):
                return "executing: \(command) error: \(error)"
            }
        }
    }

    static func version(app: URL) async throws -> String? {
        try await Command.execute(command: "defaults read \(app.appendingPathComponent("Contents/Info.plist").path) CFBundleVersion")
    }

    static func patch(app: URL, config: Config) async throws {
        try Patcher.patch(binary: app.appendingPathComponent("Contents/MacOS/WeChat"), config: config)
    }

    static func copyPlugin(app: URL) throws {
        let executableDir = URL(
            fileURLWithPath: ProcessInfo.processInfo.arguments[0]
        ).deletingLastPathComponent()
        let dylibSource = executableDir.appendingPathComponent("WeChatTweakPlugin.dylib")
        let dylibDest = app.appendingPathComponent("Contents/MacOS/WeChatTweakPlugin.dylib")

        guard FileManager.default.fileExists(atPath: dylibSource.path) else {
            print("WeChatTweakPlugin.dylib not found at \(dylibSource.path), skipping plugin.")
            return
        }

        if FileManager.default.fileExists(atPath: dylibDest.path) {
            try FileManager.default.removeItem(at: dylibDest)
        }
        try FileManager.default.copyItem(at: dylibSource, to: dylibDest)
    }

    static func injectDylib(app: URL) throws {
        let binary = app.appendingPathComponent("Contents/MacOS/WeChat")
        try DylibInjector.inject(binary: binary)
    }

    static func resign(app: URL) async throws {
        try await Command.execute(command: "codesign --remove-sign \(app.path)")
        try await Command.execute(command: "codesign --force --deep --sign - \(app.path)")
        try await Command.execute(command: "xattr -cr \(app.path)")
    }

    @discardableResult
    private static func execute(command: String) async throws -> String? {
        guard let script = NSAppleScript(source: "do shell script \"\(command)\"") else {
            throw Error.executing(
                command: command,
                error: ["error": "Create script failed."]
            )
        }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)

        if let error = error {
            throw Error.executing(
                command: command,
                error: error
            )
        } else {
            return descriptor.stringValue
        }
    }
}
