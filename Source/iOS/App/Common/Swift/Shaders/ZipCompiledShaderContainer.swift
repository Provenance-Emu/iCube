//
//  CompiledShaderContainer+Zip.swift
//  OpenEmuShaders
//
//  Created by Stuart Carnie on 19/10/2022.
//  Copyright © 2022 OpenEmu. All rights reserved.
//

import Foundation
#if canImport(Zip)
import Zip
#endif

public enum ZipCompiledShaderContainer {
    enum Error: Swift.Error {
        /// The specified path does not exist.
        case pathNotExists

        /// The specified path is not a valid archive.
        case invalidArchive

        /// The specified path is missing shader.json.
        case missingCompiledShader

        /// The platform does not provide native zip APIs.
        case unsupported
    }

    private static func makeTempDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Encode a ``Compiled.Shader`` to a ZIP archive that may be distributed.
    public static func encode(shader: Compiled.Shader, to path: URL) throws {
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }

        // Stage files in a temporary directory then zip
        let staging = try makeTempDirectory(prefix: "oe_shader_encode")
        var filesToZip: [URL] = []

        // Copy LUTs with the expected naming scheme "<lutname>__<original>"
        try shader.luts.forEach { lut in
            let filename = "\(lut.name)__\(lut.url.lastPathComponent)"
            let dst = staging.appendingPathComponent(filename)
            try FileManager.default.copyItem(at: lut.url, to: dst)
            filesToZip.append(dst)
        }

        // Write shader.json
        let je = JSONEncoder()
        je.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try je.encode(shader)
        let shaderJSON = staging.appendingPathComponent("shader.json")
        try data.write(to: shaderJSON, options: .atomic)
        filesToZip.append(shaderJSON)

        #if canImport(Zip)
        try Zip.zipFiles(paths: filesToZip, zipFilePath: path, password: nil, progress: nil)
        #else
        if #available(iOS 16.0, tvOS 16.0, *) {
            try FileManager.default.zipItem(at: staging, to: path, shouldKeepParent: false)
        } else {
            throw Error.unsupported
        }
        #endif
    }

    public final class Decoder: CompiledShaderContainer {
        public let shader: Compiled.Shader
        private let extractedDir: URL

        public convenience init(url: URL) throws {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Error.pathNotExists
            }
            let dest = try ZipCompiledShaderContainer.makeTempDirectory(prefix: "oe_shader_decode")
            do {
                #if canImport(Zip)
                try Zip.unzipFile(url, destination: dest, overwrite: true, password: nil, progress: nil)
                #else
                // If it's a directory, treat it as an already-unpacked archive
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    try FileManager.default.unzipItem(at: url, to: dest)
                } else {
                    throw Error.unsupported
                }
                #endif
            } catch {
                throw Error.invalidArchive
            }
            try self.init(extractedDir: dest)
        }

        public convenience init(data: Data) throws {
            let tempZipDir = try ZipCompiledShaderContainer.makeTempDirectory(prefix: "oe_shader_decode_data")
            let tempZip = tempZipDir.appendingPathComponent("in.zip")
            try data.write(to: tempZip)
            do {
                #if canImport(Zip)
                try Zip.unzipFile(tempZip, destination: tempZipDir, overwrite: true, password: nil, progress: nil)
                #else
                if #available(iOS 16.0, tvOS 16.0, *) {
                    try FileManager.default.unzipItem(at: tempZip, to: tempZipDir)
                } else {
                    throw Error.unsupported
                }
                #endif
            } catch {
                throw Error.invalidArchive
            }
            try self.init(extractedDir: tempZipDir)
        }

        private init(extractedDir: URL) throws {
            self.extractedDir = extractedDir
            // Locate shader.json anywhere under extractedDir
            let fm = FileManager.default
            var shaderJSON: URL?
            if let enumerator = fm.enumerator(at: extractedDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let f as URL in enumerator {
                    if f.lastPathComponent == "shader.json" {
                        shaderJSON = f
                        break
                    }
                }
            }
            guard let jsonURL = shaderJSON else { throw Error.missingCompiledShader }
            let data = try Data(contentsOf: jsonURL)
            let jd = JSONDecoder()
            shader = try jd.decode(Compiled.Shader.self, from: data)
        }

        public func getLUTByName(_ name: String) throws -> Data {
            let prefix = name + "__"
            let fm = FileManager.default
            if let enumerator = fm.enumerator(at: extractedDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let f as URL in enumerator {
                    if f.lastPathComponent.hasPrefix(prefix) {
                        return try Data(contentsOf: f)
                    }
                }
            }
            throw CompiledShaderContainerError.invalidLUTName
        }
    }
}

#if !canImport(Zip)
import Compression
private extension FileManager {
    func zipItem(at sourceURL: URL, to destinationURL: URL, shouldKeepParent: Bool) throws {
        // Directory-based fallback: just copy the directory tree to a destination folder
        let fm = self
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue else {
            // If it's a single file, wrap it into a folder
            let wrap = destinationURL
            try fm.createDirectory(at: wrap, withIntermediateDirectories: true)
            let dst = wrap.appendingPathComponent(sourceURL.lastPathComponent)
            try fm.copyItem(at: sourceURL, to: dst)
            return
        }
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        if shouldKeepParent {
            // Create parent folder and copy source folder inside
            try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let dst = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
            try fm.copyItem(at: sourceURL, to: dst)
        } else {
            // Copy contents of source into destination root
            try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)
            for item in items {
                let dst = destinationURL.appendingPathComponent(item.lastPathComponent)
                try fm.copyItem(at: item, to: dst)
            }
        }
    }
    func unzipItem(at sourceURL: URL, to destinationURL: URL) throws {
        // Directory-based fallback: if sourceURL is a directory, copy it; otherwise unsupported
        let fm = self
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue {
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)
            for item in items {
                let dst = destinationURL.appendingPathComponent(item.lastPathComponent)
                try fm.copyItem(at: item, to: dst)
            }
        } else {
            throw ZipCompiledShaderContainer.Error.unsupported
        }
    }
}
#endif
