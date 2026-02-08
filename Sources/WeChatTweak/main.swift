//
//  main.swift
//
//  Created by Sunny Young.
//

import Foundation
import Dispatch
import ArgumentParser

// MARK: Versions
extension Tweak {
    struct Versions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all supported WeChat versions")

        @OptionGroup
        var options: Tweak.Options

        mutating func run() async throws {
            print("------ Current version ------")
            print(try await Command.version(app: options.app) ?? "unknown")
            print("------ Supported versions ------")
            try await Config.load(url: options.config).forEach({ print($0.version) })
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}

// MARK: Patch
extension Tweak {
    struct Patch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Patch WeChat.app")

        @OptionGroup
        var options: Tweak.Options

        mutating func run() async throws {
            print("------ Version ------")
            let version = try await Command.version(app: options.app)
            print("WeChat version: \(version ?? "unknown")")

            print("------ Config ------")
            guard let config = (try await Config.load(url: options.config)).first(where: { $0.version == version }) else {
                throw Error.unsupportedVersion
            }
            print("Matched config: \(config)")

            print("------ Patch ------")
            try await Command.patch(
                app: options.app,
                config: config
            )
            print("Done!")

            print("------ Plugin ------")
            try Command.copyPlugin(app: options.app)
            print("Plugin copied!")
            try Command.injectDylib(app: options.app)
            print("Plugin injected!")

            print("------ Resign ------")
            try await Command.resign(
                app: options.app
            )
            print("Done!")

            Darwin.exit(EXIT_SUCCESS)
        }
    }

}

// MARK: Tweak
struct Tweak: AsyncParsableCommand {
    enum Error: LocalizedError {
        case invalidApp
        case invalidConfig
        case invalidVersion
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .invalidApp:
                return "Invalid app path"
            case .invalidConfig:
                return "Invalid patch config"
            case .invalidVersion:
                return "Invalid app version"
            case .unsupportedVersion:
                return "Unsupported WeChat version"
            }
        }
    }

    struct Options: ParsableArguments {
        @Option(
            name: .shortAndLong,
            help: "Path of WeChat.app",
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
            help: "Local path or Remote URL of config.json",
            transform: {
                if FileManager.default.fileExists(atPath: $0) {
                    return URL(fileURLWithPath: $0)
                } else {
                    guard let url = URL(string: $0) else {
                        throw Error.invalidConfig
                    }
                    return url
                }
            }
        )
        var config: URL = URL(string:"https://raw.githubusercontent.com/sunnyyoung/WeChatTweak/refs/heads/master/config.json")!
    }

    static let configuration = CommandConfiguration(
        commandName: "wechattweak",
        abstract: "A command-line tool for tweaking WeChat.",
        subcommands: [
            Versions.self,
            Patch.self
        ]
    )

    mutating func run() async throws {
        print(Tweak.helpMessage())
        Darwin.exit(EXIT_SUCCESS)
    }
}

Task {
    await Tweak.main()
}

Dispatch.dispatchMain()
