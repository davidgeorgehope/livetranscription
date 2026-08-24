#!/usr/bin/env swift
import ApplicationServices
import AppKit
import Foundation

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func dump(_ el: AXUIElement, depth: Int, maxDepth: Int, sink: inout [String]) {
    guard depth <= maxDepth else { return }
    let role = attr(el, kAXRoleAttribute as String) as? String ?? "?"
    let title = attr(el, kAXTitleAttribute as String) as? String ?? ""
    let desc = attr(el, kAXDescriptionAttribute as String) as? String ?? ""
    let value = attr(el, kAXValueAttribute as String)
    let valStr: String
    if let s = value as? String { valStr = s }
    else if let n = value as? NSNumber { valStr = n.stringValue }
    else { valStr = value.map { String(describing: $0) } ?? "" }
    let ident = attr(el, "AXIdentifier") as? String ?? ""
    let selected = attr(el, kAXSelectedAttribute as String) as? Bool
    let focused = attr(el, kAXFocusedAttribute as String) as? Bool
    let line = String(repeating: "  ", count: depth)
        + "\(role) title=\(title.prefix(80)) desc=\(desc.prefix(80)) val=\(String(valStr.prefix(80))) id=\(ident) sel=\(String(describing: selected)) foc=\(String(describing: focused))"
    let interesting = [title, desc, valStr, ident, role].joined(separator: " ").lowercased()
    if interesting.contains("speak") || interesting.contains("participant")
        || interesting.contains("active") || interesting.contains("host")
        || role == "AXWindow" || depth <= 2 {
        sink.append(line)
    }
    for child in children(el) {
        dump(child, depth: depth + 1, maxDepth: maxDepth, sink: &sink)
    }
}

guard AXIsProcessTrusted() else {
    print("AX_TRUSTED=false — grant Accessibility to this process and rerun")
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    exit(2)
}
print("AX_TRUSTED=true")

let apps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "us.zoom.xos" || ($0.localizedName?.lowercased().contains("zoom") ?? false)
}
guard let zoom = apps.first, zoom.processIdentifier != 0 else {
    print("Zoom not running")
    exit(1)
}
print("Zoom pid=\(zoom.processIdentifier) name=\(zoom.localizedName ?? "?")")

let appEl = AXUIElementCreateApplication(zoom.processIdentifier)
var lines: [String] = []
dump(appEl, depth: 0, maxDepth: 8, sink: &lines)
let out = "/tmp/cue-zoom-ax.txt"
try! lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
print("Wrote \(lines.count) lines to \(out)")
print(lines.prefix(40).joined(separator: "\n"))
