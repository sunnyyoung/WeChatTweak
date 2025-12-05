//
//  main.swift
//
//  Created by Sunny Young.
//

import Foundation
import PromiseKit
import ArgumentParser

struct Patch: ParsableCommand {
    enum Error: LocalizedError {
        case invalidApp
        case invalidConfig
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .invalidApp:
                return "Invalid app path"
            case .invalidConfig:
                return "Invalid patch config"
            case .unsupportedVersion:
                return "Unsupported WeChat version"
            }
        }
    }

    static let configuration = CommandConfiguration(abstract: "Patch WeChat.app")

    @Option(
        name: .shortAndLong,
        help: "Default: /Applications/WeChat.app",
        transform: {
            guard FileManager.default.fileExists(atPath: $0) else {
                throw Error.invalidApp
            }
            return URL(fileURLWithPath: $0)
        }
    )
    var app: URL = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)

    @Option(
        name: .shortAndLong,
        help: "Default: ./config.json",
        transform: {
            guard FileManager.default.fileExists(atPath: $0) else {
                throw Error.invalidConfig
            }
            return URL(fileURLWithPath: $0)
        }
    )
    var config: URL = {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0, let path = String(utf8String: buffer) else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("config.json")
    }()

    func run() throws {
        let configs = try JSONDecoder().decode([Config].self, from: Data(contentsOf: self.config))

        guard
            let info = NSDictionary(contentsOf: self.app.appendingPathComponent("Contents/Info.plist")),
            let version = info["CFBundleVersion"] as? String,
            let config = configs.first(where: { $0.version == version })
        else {
            throw Error.unsupportedVersion
        }

        firstly {
            Command.patch(
                app: self.app,
                config: config
            )
        }.then {
            Command.resign(app: self.app)
        }.ensure {
            print("")
        }.done {
            print("🎉 Done!")
            Darwin.exit(EXIT_SUCCESS)
        }.catch { error in
            print("🚨 \(error.localizedDescription)", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
    }
}

struct Tweak: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wechattweak",
        abstract: "A command-line tool for tweaking WeChat.",
        subcommands: [
            Patch.self
        ],
        defaultSubcommand: Self.self
    )
}

Tweak.main()
CFRunLoopRun()
