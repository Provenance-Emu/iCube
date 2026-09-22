// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

public struct WikiSection: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public var items: [WikiNavItem]

    public init(id: String? = nil, title: String, items: [WikiNavItem] = []) {
        self.id = id ?? title.lowercased().replacingOccurrences(of: " ", with: "-")
        self.title = title
        self.items = items
    }
}

public struct WikiNavItem: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let path: String
    public var children: [WikiNavItem]

    public init(title: String, path: String, children: [WikiNavItem] = []) {
        self.id = path.isEmpty ? title.lowercased().replacingOccurrences(of: " ", with: "-") : path
        self.title = title
        self.path = path
        self.children = children
    }
}

public struct WikiNavigationTree: Codable, Sendable {
    public let sections: [WikiSection]

    public init(sections: [WikiSection]) {
        self.sections = sections
    }

    /// Paths that must not appear in the in-app wiki to comply with App Store guidelines
    /// (sideloading instructions, jailbreak/TrollStore instructions, dev-signing, etc.) on the
    /// `Release (AppStore)` configuration. iCube's own sideload/jailbroken build variants are
    /// unaffected — this filter only matters for what ships to the App Store review team and
    /// App Store users. Ported from Provenance's PVHelp, where the same App Store constraints
    /// forced exactly this shape; kept here so future wiki pages (e.g. a jailbreak install
    /// guide) can be added without a fresh audit of what's App-Store-safe.
    private static let blockedPaths: Set<String> = [
        "installation-and-usage/installing-provenance/sideloading.md",
        "installation-and-usage/installing-provenance/building-from-source.md",
        "info/miscellaneous/virtualizing-macos.md",
    ]

    /// Keywords in page paths that signal App Store-unsafe content. Matched as substrings, so
    /// every entry here must be long and distinctive enough that it cannot appear inside an
    /// innocent word (see `testShortKeywordOnlyMatchesWholePathComponent` for why "ipa" as a
    /// substring keyword would be a bug, not a feature).
    private static let blockedKeywords: [String] = [
        "sideload", "jailbreak", "altstore", "signing-service",
        "testflight", "developer-account", "provisioning", "trollstore"
    ]

    /// Short keywords that are only meaningful as a whole path component.
    private static let blockedPathComponents: Set<String> = [
        "ipa"
    ]

    /// Characters that separate meaningful components of a wiki path.
    private static let pathComponentSeparators = CharacterSet(charactersIn: "/-_.")

    private static func isBlocked(path: String) -> Bool {
        let lower = path.lowercased()
        if blockedPaths.contains(lower) { return true }
        if blockedKeywords.contains(where: { lower.contains($0) }) { return true }
        let components = lower.components(separatedBy: pathComponentSeparators)
        return components.contains(where: { blockedPathComponents.contains($0) })
    }

    /// Recursively strip blocked items from a list of nav items.
    private static func filterItems(_ items: [WikiNavItem]) -> [WikiNavItem] {
        items.compactMap { item in
            guard !isBlocked(path: item.path) else { return nil }
            var filtered = item
            filtered.children = filterItems(item.children)
            return filtered
        }
    }

    /// Re-applies the App Store content filter to an already-decoded tree.
    /// Call this on trees loaded from cache to catch any newly-blocked paths.
    public func appStoreFiltered() -> WikiNavigationTree {
        let filtered = sections.compactMap { section -> WikiSection? in
            var s = section
            s.items = WikiNavigationTree.filterItems(s.items)
            return s.items.isEmpty && !s.title.isEmpty ? nil : s
        }
        return WikiNavigationTree(sections: filtered)
    }

    /// Parse a GitBook SUMMARY.md into a navigation tree.
    public static func parse(markdown: String) -> WikiNavigationTree {
        var sections: [WikiSection] = []
        var currentSection: WikiSection?
        var itemStack: [(indent: Int, items: [WikiNavItem])] = []

        func flushStack() -> [WikiNavItem] {
            while itemStack.count > 1 {
                let child = itemStack.removeLast()
                if var parent = itemStack.last, !parent.items.isEmpty {
                    let lastIndex = parent.items.count - 1
                    parent.items[lastIndex].children.append(contentsOf: child.items)
                    itemStack[itemStack.count - 1] = parent
                }
            }
            return itemStack.first?.items ?? []
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if var sec = currentSection {
                    sec.items = flushStack()
                    sections.append(sec)
                    itemStack = []
                }
                let title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentSection = WikiSection(title: title)
                continue
            }

            guard let match = parseNavLine(line) else { continue }

            let item = WikiNavItem(title: match.title, path: match.path)
            let indent = match.indent

            if currentSection == nil {
                currentSection = WikiSection(id: "root", title: "")
            }

            if itemStack.isEmpty {
                itemStack.append((indent: indent, items: [item]))
            } else if indent > itemStack.last!.indent {
                itemStack.append((indent: indent, items: [item]))
            } else if indent == itemStack.last!.indent {
                itemStack[itemStack.count - 1].items.append(item)
            } else {
                while itemStack.count > 1 && itemStack.last!.indent > indent {
                    let child = itemStack.removeLast()
                    if !itemStack.isEmpty && !itemStack.last!.items.isEmpty {
                        let lastIndex = itemStack[itemStack.count - 1].items.count - 1
                        itemStack[itemStack.count - 1].items[lastIndex].children.append(contentsOf: child.items)
                    }
                }
                if itemStack.last?.indent == indent {
                    itemStack[itemStack.count - 1].items.append(item)
                } else {
                    itemStack.append((indent: indent, items: [item]))
                }
            }
        }

        if var sec = currentSection {
            sec.items = flushStack()
            sections.append(sec)
        }

        let filtered = sections.compactMap { section -> WikiSection? in
            var s = section
            s.items = filterItems(s.items)
            return s.items.isEmpty && !s.title.isEmpty ? nil : s
        }

        return WikiNavigationTree(sections: filtered)
    }

    private struct ParsedNavLine {
        let indent: Int
        let title: String
        let path: String
    }

    private static func parseNavLine(_ line: String) -> ParsedNavLine? {
        let stripped = line.replacingOccurrences(of: "\t", with: "  ")
        let leadingSpaces = stripped.prefix(while: { $0 == " " }).count

        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") else { return nil }

        let afterBullet = String(trimmed.dropFirst(2))

        guard afterBullet.hasPrefix("["),
              let closeBracket = afterBullet.firstIndex(of: "]"),
              afterBullet[afterBullet.index(after: closeBracket)] == "(" else {
            return nil
        }

        let title = String(afterBullet[afterBullet.index(after: afterBullet.startIndex)..<closeBracket])
        let afterParen = afterBullet[afterBullet.index(closeBracket, offsetBy: 2)...]
        guard let closeParen = afterParen.firstIndex(of: ")") else { return nil }
        let path = String(afterParen[..<closeParen])

        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return nil
        }

        return ParsedNavLine(indent: leadingSpaces, title: title, path: path)
    }
}
