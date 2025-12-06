//
//  main.swift
//
//  Created by Sunny Young.
//

import Foundation
import Dispatch
import ArgumentParser

struct Patch: AsyncParsableCommand {
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

    static let configuration = CommandConfiguration(abstract: "Patch WeChat.app")

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
    var config: URL = URL(string: "https://raw.githubusercontent.com/sunnyyoung/WeChatTweak/refs/heads/feature/2.0/config.json")!

    mutating func run() async throws {
        do {
            print("------ Version ------")
            guard let version = try await Command.version(app: self.app) else {
                throw Error.invalidVersion
            }
            print("\(version)")

            print("------ Config ------")
            guard let config = (try await Config.load(from: self.config)).first(where: { $0.version == version }) else {
                throw Error.unsupportedVersion
            }
            print("\(config)")

            print("------ Patch ------")
            try await Command.patch(
                app: self.app,
                config: config
            )
            print("Done!")

            print("------ Resign ------")
            try await Command.resign(
                app: self.app
            )
            print("Done!")

            print("------🎉 Done!------")
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            print("------🚨 Error------")
            print("\(error.localizedDescription)")
            Darwin.exit(EXIT_FAILURE)
        }
    }
}

struct Tweak: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wechattweak",
        abstract: "A command-line tool for tweaking WeChat.",
        subcommands: [
            Patch.self
        ],
        defaultSubcommand: Self.self
    )
}

Task {
    await Tweak.main()
}

Dispatch.dispatchMain()
