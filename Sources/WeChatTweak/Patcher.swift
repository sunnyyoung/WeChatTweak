//
//  Patcher.swift
//  WeChatTweak
//
//  Created by Sunny Young on 2025/12/4.
//

import Darwin
import MachO
import Foundation

struct Patcher {
    enum Error: Swift.Error {
        case invalidFile
        case not64BitMachO(magic: UInt32)
        case vaNotFound(arch: String, va: UInt64)
        case noArchMatched
    }

    static func patch(binary: URL, config: Config) throws {
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw Error.invalidFile
        }

        let entries = config.targets.flatMap { $0.entries }
        guard !entries.isEmpty else { throw Error.noArchMatched }

        let fh = try FileHandle(forUpdating: binary)
        defer { try? fh.close() }

        // 读 magic 判断 fat / thin
        guard let magicData = try fh.read(upToCount: 4), magicData.count == 4 else {
            throw Error.invalidFile
        }
        let magicBE = magicData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let isSwappedFat = (magicBE == FAT_CIGAM)

        var patchedCount = 0
        if magicBE == FAT_MAGIC || magicBE == FAT_CIGAM {
            // FAT header: magic(4) + nfat_arch(4)
            guard let nfatData = try fh.read(upToCount: 4), nfatData.count == 4 else {
                throw Error.invalidFile
            }
            let rawNfat = nfatData.withUnsafeBytes { $0.load(as: UInt32.self) }
            let nfat = isSwappedFat ? UInt32(littleEndian: rawNfat) : UInt32(bigEndian: rawNfat)

            // 先读完 fat_arch 表，避免 patch 时移动文件指针影响后续读取
            var archEntries: [(cputype: UInt32, offset: UInt32)] = []

            for _ in 0..<nfat {
                // fat_arch: cputype(4) cpusub(4) offset(4) size(4) align(4) big-endian
                guard let archData = try fh.read(upToCount: 20), archData.count == 20 else {
                    throw Error.invalidFile
                }
                let rawCpu = archData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                let rawOff = archData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                let cputype = isSwappedFat ? UInt32(littleEndian: rawCpu) : UInt32(bigEndian: rawCpu)
                let offset  = isSwappedFat ? UInt32(littleEndian: rawOff) : UInt32(bigEndian: rawOff)
                archEntries.append((cputype, offset))
            }

            for entry in archEntries {
                let matching = entries.filter { $0.arch.cpu == entry.cputype }
                for target in matching {
                    try patchOneSlice(file: fh,
                                      sliceOffset: UInt64(entry.offset),
                                      targetVA: target.addr,
                                      patch: target.asm,
                                      archName: target.arch.rawValue)
                    patchedCount += 1
                }
            }
        } else {
            // thin mach-o：回到开头按 mach_header_64 解析（小端）
            try fh.seek(toOffset: 0)
            guard let hdr = try fh.read(upToCount: 32), hdr.count == 32 else {
                throw Error.invalidFile
            }
            let magic = hdr.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let cputype = hdr.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self).littleEndian }

            guard magic == MH_MAGIC_64 else {
                throw Error.not64BitMachO(magic: magic)
            }

            let matching = entries.filter { Int32(bitPattern: $0.arch.cpu) == cputype }
            if matching.isEmpty {
                throw Error.noArchMatched
            }

            for target in matching {
                try patchOneSlice(file: fh,
                                  sliceOffset: 0,
                                  targetVA: target.addr,
                                  patch: target.asm,
                                  archName: target.arch.rawValue)
                patchedCount += 1
            }
        }

        if patchedCount <= 0 {
            throw Error.noArchMatched
        }
    }

    private static func patchOneSlice(file fh: FileHandle,
                                      sliceOffset: UInt64,
                                      targetVA: UInt64,
                                      patch: Data,
                                      archName: String) throws {

        // 读 slice 内 mach_header_64
        try fh.seek(toOffset: sliceOffset)
        guard let hdr = try fh.read(upToCount: 32), hdr.count == 32 else {
            throw Error.invalidFile
        }

        let magic   = hdr.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let ncmds   = hdr.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self).littleEndian }

        guard magic == MH_MAGIC_64 else {
            throw Error.not64BitMachO(magic: magic)
        }

        var lcOffset = sliceOffset + 32

        for _ in 0..<ncmds {
            try fh.seek(toOffset: lcOffset)
            guard let lcHead = try fh.read(upToCount: 8), lcHead.count == 8 else {
                throw Error.invalidFile
            }

            let cmd     = lcHead.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let cmdsize = lcHead.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }

            if cmd == LC_SEGMENT_64 {
                guard let segData = try fh.read(upToCount: 64), segData.count == 64 else {
                    throw Error.invalidFile
                }

                let vmaddr  = segData.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self).littleEndian }
                let vmsize  = segData.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self).littleEndian }
                let fileoff = segData.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt64.self).littleEndian }

                if vmaddr <= targetVA && targetVA < vmaddr + vmsize {
                    let fileOffset = sliceOffset + fileoff + (targetVA - vmaddr)
                    print("[\(archName)] vmaddr=\(String(format: "0x%llx", vmaddr)), fileoff=\(String(format: "0x%llx", fileoff)), sliceoff=\(String(format: "0x%llx", sliceOffset))")
                    print("[\(archName)] patch VA=\(String(format: "0x%llx", targetVA)), fileoff=\(String(format: "0x%llx", fileOffset))")

                    try fh.seek(toOffset: fileOffset)
                    try fh.write(contentsOf: patch)
                    return
                }
            }

            lcOffset += UInt64(cmdsize)
        }

        throw Error.vaNotFound(arch: archName, va: targetVA)
    }
}
