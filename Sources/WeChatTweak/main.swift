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
            try await Tweak.versions().forEach { print($0) }
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
            guard let version = try await Command.version(app: self.options.app), let targets = try await Tweak.load(version: version) else {
                throw Error.unsupportedVersion
            }
            print("\(version)")

            print("------ Patch ------")
            try await Command.patch(
                app: self.options.app,
                targets: targets
            )
            print("Done!")

            print("------ Resign ------")
            try await Command.resign(
                app: self.options.app
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
            help: "Local path or Remote URL of config (default: derived from app version)",
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
        var config: URL? = nil
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

extension Tweak {
    static func load(url: URL) async throws -> [Target] {
        let data = try await {
            if url.isFileURL {
                return try Data(contentsOf: url)
            } else {
                return try await URLSession.shared.data(from: url).0
            }
        }()
        return try JSONDecoder().decode([Target].self, from: data)
    }

    static func load(version: String) async throws -> [Target]? {
        guard try await Tweak.versions().contains(version) else {
            return nil
        }
        return try await Self.load(url: URL(string: "https://raw.githubusercontent.com/sunnyyoung/WeChatTweak/master/Versions/\(version).json")!)
    }

    static func versions() async throws -> [String] {
        let data = try await URLSession.shared.data(
            for: URLRequest(
                url: URL(string: "https://api.github.com/repos/sunnyyoung/WeChatTweak/contents/Versions")!
            )
        )
        return (try JSONSerialization.jsonObject(with: data.0) as? [[String: Any]])?.compactMap { ($0["name"] as? NSString)?.deletingPathExtension } ?? []
    }
}

Task {
    await Tweak.main()
}

Dispatch.dispatchMain()
