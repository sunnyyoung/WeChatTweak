//
//  Command.swift
//
//  Created by Sunny Young.
//

import Foundation
import PromiseKit
import ArgumentParser

struct Command {
    enum Error: @unchecked Sendable, LocalizedError {
        case executing(command: String, error: NSDictionary)

        var errorDescription: String? {
            switch self {
            case let .executing(command, error):
                return "Execute command: \(command) failed: \(error)"
            }
        }
    }

    static func patch(app: URL, config: Config) -> Promise<Void> {
        print("------ Path ------")
        return Promise { seal in
            do {
                seal.fulfill(try Patcher.patch(binary: app.appendingPathComponent("Contents/MacOS/WeChat"), config: config))
            } catch {
                seal.reject(error)
            }
        }
    }

    static func resign(app: URL) -> Promise<Void> {
        print("------ Resign ------")
        return firstly {
            Command.execute(command: "codesign --remove-sign \(app.path)")
        }.then {
            Command.execute(command: "codesign --force --deep --sign - \(app.path)")
        }.then {
            Command.execute(command: "xattr -cr \(app.path)")
        }
    }

    private static func execute(command: String) -> Promise<Void> {
        return Promise { seal in
            print("Execute command: \(command)")
            var error: NSDictionary?
            guard let script = NSAppleScript(source: "do shell script \"\(command)\"") else {
                return seal.reject(Error.executing(command: command, error: ["error": "Create script failed."]))
            }
            script.executeAndReturnError(&error)
            if let error = error {
                seal.reject(Error.executing(command: command, error: error))
            } else {
                seal.fulfill(())
            }
        }
    }
}
