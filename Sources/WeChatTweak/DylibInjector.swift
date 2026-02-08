//
//  DylibInjector.swift
//  WeChatTweak
//
//  Injects LC_LOAD_DYLIB into Mach-O binaries.
//

import Darwin
import MachO
import Foundation

struct DylibInjector {
    enum Error: Swift.Error, LocalizedError {
        case invalidFile
        case not64BitMachO(magic: UInt32)
        case dylibAlreadyInjected
        case noSpaceForLoadCommand(available: Int, required: Int)

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return "Invalid Mach-O file"
            case .not64BitMachO(let magic):
                return "Not a 64-bit Mach-O (magic: \(String(format: "0x%x", magic)))"
            case .dylibAlreadyInjected:
                return "Dylib already injected"
            case .noSpaceForLoadCommand(let available, let required):
                return "No space for load command (available: \(available), required: \(required))"
            }
        }
    }

    static let dylibPath = "@executable_path/WeChatTweakPlugin.dylib"

    static func inject(binary: URL) throws {
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw Error.invalidFile
        }

        let fh = try FileHandle(forUpdating: binary)
        defer { try? fh.close() }

        guard let magicData = try fh.read(upToCount: 4), magicData.count == 4 else {
            throw Error.invalidFile
        }
        let magicBE = magicData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let isSwappedFat = (magicBE == FAT_CIGAM)

        if magicBE == FAT_MAGIC || magicBE == FAT_CIGAM {
            guard let nfatData = try fh.read(upToCount: 4), nfatData.count == 4 else {
                throw Error.invalidFile
            }
            let rawNfat = nfatData.withUnsafeBytes { $0.load(as: UInt32.self) }
            let nfat = isSwappedFat ? UInt32(littleEndian: rawNfat) : UInt32(bigEndian: rawNfat)

            var sliceOffsets: [UInt64] = []
            for _ in 0..<nfat {
                guard let archData = try fh.read(upToCount: 20), archData.count == 20 else {
                    throw Error.invalidFile
                }
                let rawCpu = archData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                let rawOff = archData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                let cputype = isSwappedFat ? UInt32(littleEndian: rawCpu) : UInt32(bigEndian: rawCpu)
                let offset = isSwappedFat ? UInt32(littleEndian: rawOff) : UInt32(bigEndian: rawOff)
                if cputype == UInt32(CPU_TYPE_ARM64) {
                    sliceOffsets.append(UInt64(offset))
                }
            }

            for sliceOffset in sliceOffsets {
                try injectOneSlice(file: fh, sliceOffset: sliceOffset)
            }
        } else {
            try fh.seek(toOffset: 0)
            guard let hdr = try fh.read(upToCount: 32), hdr.count == 32 else {
                throw Error.invalidFile
            }
            let magic = hdr.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            guard magic == MH_MAGIC_64 else {
                throw Error.not64BitMachO(magic: magic)
            }
            try injectOneSlice(file: fh, sliceOffset: 0)
        }
    }

    private static func injectOneSlice(file fh: FileHandle,
                                        sliceOffset: UInt64) throws {
        // Read mach_header_64
        try fh.seek(toOffset: sliceOffset)
        guard let hdr = try fh.read(upToCount: 32), hdr.count == 32 else {
            throw Error.invalidFile
        }

        let magic = hdr.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard magic == MH_MAGIC_64 else {
            throw Error.not64BitMachO(magic: magic)
        }

        let ncmds = hdr.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self).littleEndian }
        let sizeofcmds = hdr.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self).littleEndian }

        // Scan existing load commands
        var lcOffset = sliceOffset + 32
        var minSectionFileOffset: UInt64 = UInt64.max

        for _ in 0..<ncmds {
            try fh.seek(toOffset: lcOffset)
            guard let lcHead = try fh.read(upToCount: 8), lcHead.count == 8 else {
                throw Error.invalidFile
            }

            let cmd = lcHead.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let cmdsize = lcHead.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }

            // Check for existing LC_LOAD_DYLIB with same path
            if cmd == UInt32(LC_LOAD_DYLIB) {
                try fh.seek(toOffset: lcOffset + 8)
                guard let rest = try fh.read(upToCount: Int(cmdsize) - 8),
                      rest.count == Int(cmdsize) - 8 else {
                    throw Error.invalidFile
                }
                // name offset at bytes 0..4 of rest (relative to start of command)
                let nameOffset = rest.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                let nameStart = Int(nameOffset) - 8 // offset within 'rest' data
                if nameStart >= 0 && nameStart < rest.count {
                    let nameData = rest[nameStart...]
                    if let end = nameData.firstIndex(of: 0) {
                        let name = String(data: nameData[nameStart..<end], encoding: .utf8)
                        if name == dylibPath {
                            print("Dylib already injected, skipping.")
                            return
                        }
                    }
                }
            }

            // Track minimum section file offset for space calculation
            if cmd == LC_SEGMENT_64 {
                try fh.seek(toOffset: lcOffset + 8)
                guard let segBody = try fh.read(upToCount: 64), segBody.count == 64 else {
                    throw Error.invalidFile
                }
                let nsects = segBody.withUnsafeBytes {
                    $0.load(fromByteOffset: 56, as: UInt32.self).littleEndian
                }

                // Read each section_64 (80 bytes each)
                for j in 0..<nsects {
                    let sectOffset = lcOffset + 8 + 64 + UInt64(j) * 80
                    try fh.seek(toOffset: sectOffset + 48) // section_64.offset
                    guard let offData = try fh.read(upToCount: 4), offData.count == 4 else {
                        throw Error.invalidFile
                    }
                    let sectFileOff = offData.withUnsafeBytes {
                        $0.load(as: UInt32.self).littleEndian
                    }
                    if sectFileOff > 0 {
                        minSectionFileOffset = min(minSectionFileOffset, UInt64(sectFileOff))
                    }
                }
            }

            lcOffset += UInt64(cmdsize)
        }

        // Calculate available space
        let endOfLC = UInt64(32 + sizeofcmds) // relative to slice start
        let available: Int
        if minSectionFileOffset != UInt64.max {
            available = Int(minSectionFileOffset) - Int(endOfLC)
        } else {
            available = 0
        }

        // Build dylib_command
        let dylibCmd = buildDylibCommand(path: dylibPath)

        guard available >= dylibCmd.count else {
            throw Error.noSpaceForLoadCommand(available: available, required: dylibCmd.count)
        }

        // Write dylib_command at end of existing load commands
        try fh.seek(toOffset: sliceOffset + endOfLC)
        try fh.write(contentsOf: dylibCmd)

        // Update header: ncmds and sizeofcmds
        let newNcmds = ncmds + 1
        let newSizeofcmds = sizeofcmds + UInt32(dylibCmd.count)

        var ncmdsBytes = newNcmds.littleEndian
        var sizeBytes = newSizeofcmds.littleEndian

        try fh.seek(toOffset: sliceOffset + 16)
        try fh.write(contentsOf: Data(bytes: &ncmdsBytes, count: 4))
        try fh.write(contentsOf: Data(bytes: &sizeBytes, count: 4))

        print("LC_LOAD_DYLIB injected at slice offset \(String(format: "0x%llx", sliceOffset))")
    }

    private static func buildDylibCommand(path: String) -> Data {
        let pathBytes = Array(path.utf8) + [0] // null-terminated
        let fixedSize = 24 // cmd(4) + cmdsize(4) + name_offset(4) + timestamp(4) + cur_ver(4) + compat_ver(4)
        let rawSize = fixedSize + pathBytes.count
        let cmdsize = (rawSize + 7) & ~7 // align to 8

        var data = Data(capacity: cmdsize)

        // cmd: LC_LOAD_DYLIB = 0x0C
        var cmd: UInt32 = UInt32(LC_LOAD_DYLIB).littleEndian
        data.append(Data(bytes: &cmd, count: 4))

        // cmdsize
        var size: UInt32 = UInt32(cmdsize).littleEndian
        data.append(Data(bytes: &size, count: 4))

        // name offset (from start of command)
        var nameOffset: UInt32 = UInt32(24).littleEndian
        data.append(Data(bytes: &nameOffset, count: 4))

        // timestamp
        var timestamp: UInt32 = 0
        data.append(Data(bytes: &timestamp, count: 4))

        // current_version
        var currentVersion: UInt32 = 0
        data.append(Data(bytes: &currentVersion, count: 4))

        // compatibility_version
        var compatVersion: UInt32 = 0
        data.append(Data(bytes: &compatVersion, count: 4))

        // path string
        data.append(contentsOf: pathBytes)

        // padding
        let padding = cmdsize - rawSize
        if padding > 0 {
            data.append(Data(repeating: 0, count: padding))
        }

        return data
    }
}
