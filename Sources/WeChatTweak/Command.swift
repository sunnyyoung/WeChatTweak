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

    @discardableResult
    static func patch(app: URL, config: Config) async throws -> [URL] {
        // 4.2 moved the app's code from Contents/MacOS/WeChat to
        // Contents/Resources/wechat.dylib, so one run may patch several files.
        let groups = Dictionary(grouping: config.targets) { target in
            target.file ?? "Contents/MacOS/WeChat"
        }

        var modified: [URL] = []
        for (path, targets) in groups.sorted(by: { $0.key < $1.key }) {
            let binary = app.appendingPathComponent(path)
            try Patcher.patch(
                binary: binary,
                config: Config(version: config.version, targets: targets)
            )
            modified.append(binary)
        }
        return modified
    }

    static func resign(app: URL, modified: [URL]) async throws {
        // `codesign --deep` does not descend into Contents/Resources, so the
        // patched Mach-O files have to be signed explicitly before the app.
        //
        // `--preserve-metadata=entitlements` matters on WeChat 4.2: without the
        // sandbox entitlements the client cannot find its container, and
        // `--deep` is still required because the ad-hoc main executable and the
        // Tencent-signed frameworks must end up with the same (empty) Team ID,
        // otherwise dyld refuses to load libwxld.dylib.
        for binary in modified {
            try await Command.execute(command: "codesign --force --sign - '\(binary.path)'")
        }
        try await Command.execute(command: "codesign --force --deep --sign - --preserve-metadata=entitlements '\(app.path)'")
        try await Command.execute(command: "xattr -cr '\(app.path)'")
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
