import AppKit
import Foundation
import Carbon.HIToolbox
import ServiceManagement

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fatalError("FAIL: \(description)") }
    checks += 1
}

var history = History()
check(!history.record(" \n\t", limit: 3), "ignore blank strings")
check(!history.record(String(repeating: "a", count: History.maximumTextBytes + 1), limit: 3), "ignore oversized text")
history.record("Alpha\n第一行", limit: 3)
let identity = history.entries[0].id
history.record("Beta", limit: 3)
history.record("Alpha\n第一行", limit: 3)
check(history.entries.map(\.text) == ["Alpha\n第一行", "Beta"], "deduplicate and promote to newest")
check(history.entries[0].id == identity, "preserve identity on repeat")
check(history.matching("alpha").count == 1, "case insensitive search")
check(history.matching("第一行").count == 1, "Chinese multiline search")
history.record(" Alpha\n第一行", limit: 3)
check(history.entries.count == 3, "preserve whitespace differences")
history.record("Gamma", limit: 3)
check(history.entries.count == 3 && !history.entries.contains { $0.text == "Beta" }, "evict oldest at count limit")
history.trim(limit: 1)
check(history.entries.map(\.text) == ["Gamma"], "reduce capacity immediately")
var large = History()
let largeCount = History.maximumTotalBytes / 100_000 + 10
for index in 0..<largeCount { large.record("\(index)" + String(repeating: "x", count: 100_000), limit: 1000) }
check(large.entries.reduce(0) { $0 + $1.text.utf8.count } <= History.maximumTotalBytes, "bound total storage")
check(large.entries.count < largeCount && large.entries[0].text.hasPrefix("\(largeCount - 1)"), "byte limit evicts oldest")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardTests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
let url = directory.appendingPathComponent("history.json")
let store = try HistoryStore(url: url, limit: 200)
try store.record("持久化\n🐈", limit: 200)
let reloaded = try HistoryStore(url: url, limit: 200)
check(reloaded.history.entries == store.history.entries, "round trip persistence")
let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "history file is private")
try store.clear()
let cleared = try HistoryStore(url: url, limit: 200)
check(cleared.history.entries.isEmpty, "clear survives restart")
let broken = Data("invalid-json".utf8)
try broken.write(to: url)
do { _ = try HistoryStore(url: url, limit: 200); fatalError("corruption should be reported") }
catch { checks += 1 }
let preserved = try Data(contentsOf: url)
check(preserved == broken, "keep corrupted data for recovery")

let pasteboard = NSPasteboard.withUniqueName()
defer { pasteboard.releaseGlobally() }
pasteboard.setString("before startup", forType: .string)
let monitor = ClipboardMonitor(pasteboard: pasteboard)
var captured: [String] = []
monitor.onContent = { if case .text(let text) = $0 { captured.append(text) } }
monitor.poll()
check(captured.isEmpty, "do not capture pre-launch clipboard")
func setClipboard(_ text: String) {
    pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
}
setClipboard("first"); monitor.poll(); monitor.poll()
check(captured == ["first"], "record each change once")
monitor.paused = true
setClipboard("private"); monitor.poll()
setClipboard("also private")
monitor.paused = false; monitor.poll()
check(captured == ["first"], "do not backfill paused changes")
setClipboard("resumed"); monitor.poll()
check(captured.last == "resumed", "record after resume")
check(monitor.copy("historical"), "copy history")
monitor.poll()
check(captured.count == 2 && pasteboard.string(forType: .string) == "historical", "ignore own clipboard write")
setClipboard("concealed")
pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
monitor.poll()
check(captured.count == 2, "respect concealed clipboard marker")
setClipboard("discarded"); monitor.discardCurrentChange(); monitor.poll()
check(captured.count == 2, "clear does not reimport pending copy")

// Real encoded PNG/TIFF fixtures, isolated clipboard, and disk round trips.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
for x in 0..<12 { for y in 0..<8 {
    bitmap.setColor(NSColor(deviceRed: 0.9, green: 0.2, blue: 0.1, alpha: x < 6 ? 0.5 : 1), atX: x, y: y)
} }
let rawPNG = bitmap.representation(using: .png, properties: [:])!
let rawTIFF = bitmap.representation(using: .tiff, properties: [:])!
let image = ClipboardImage(data: rawPNG)!
let tiffImage = ClipboardImage(data: rawTIFF)!
check(image.width == 12 && image.height == 8, "retain image dimensions")
check(tiffImage.width == 12 && tiffImage.height == 8, "read TIFF clipboard images")
check(ClipboardImage(data: Data("broken image".utf8)) == nil, "reject invalid image data")
let decodedPNG = NSBitmapImageRep(data: image.pngData)!
check(abs(decodedPNG.colorAt(x: 0, y: 0)!.alphaComponent - 0.5) < 0.02, "retain PNG transparency")
check(image.thumbnail(maxPixels: 4)!.size.width <= 4, "generate bounded thumbnail")
let largeBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 5120, pixelsHigh: 2880,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
largeBitmap.bitmapData!.initialize(repeating: 255, count: largeBitmap.bytesPerRow * largeBitmap.pixelsHigh)
let largeTIFF = largeBitmap.representation(using: .tiff, properties: [:])!
check(largeTIFF.count > 50 * 1024 * 1024 && ClipboardImage(data: largeTIFF)?.width == 5120,
      "accept uncompressed 5K screenshot TIFF within pixel and PNG size limits")
var mixed = History()
mixed.record("文字", limit: 3)
mixed.record(.image(image), limit: 3)
let imageIdentity = mixed.entries[0].id
mixed.record("other", limit: 3)
mixed.record(.image(image), limit: 3)
check(mixed.entries.count == 3 && mixed.entries[0].id == imageIdentity, "deduplicate image and promote without changing identity")
check(mixed.matching("图片").count == 1 && mixed.matching("IMAGE").count == 1, "search image type in Chinese and English")
check(mixed.matching("12").count == 1, "search image dimensions")
mixed.trim(limit: 1)
check(mixed.entries.count == 1 && mixed.entries[0].image != nil, "share count limit across images and text")

let imageIndex = directory.appendingPathComponent("image-history/history.json")
let imageStore = try HistoryStore(url: imageIndex, limit: 200)
try imageStore.record("existing text", limit: 200)
try imageStore.record(.image(image), limit: 200)
let restoredImages = try HistoryStore(url: imageIndex, limit: 200)
check(restoredImages.history.entries == imageStore.history.entries, "restore mixed text/image history after restart")
let imageFolder = imageIndex.deletingLastPathComponent().appendingPathComponent("images")
let imageFile = imageFolder.appendingPathComponent(image.digest + ".png")
let savedPNG = try Data(contentsOf: imageFile)
check(savedPNG == image.pngData, "persist image as separate PNG")
let imageAttributes = try FileManager.default.attributesOfItem(atPath: imageFile.path)
check((imageAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "image files are private")
let indexData = try Data(contentsOf: imageIndex)
check(indexData.count < 2048 && !String(decoding: indexData, as: UTF8.self).contains("pngData"), "index contains references instead of embedded images")
try imageStore.record(.image(image), limit: 200)
let assetFiles = try FileManager.default.contentsOfDirectory(atPath: imageFolder.path)
check(assetFiles.count == 1, "dedup shares disk asset")

var imageCaptures: [ClipboardContent] = []
monitor.onContent = { imageCaptures.append($0) }
pasteboard.clearContents()
pasteboard.setData(rawPNG, forType: .png)
pasteboard.setString("companion URL", forType: .string)
monitor.poll(); monitor.poll()
check(imageCaptures == [.image(image)], "capture PNG once and prefer it over companion text")
pasteboard.clearContents(); pasteboard.setData(rawTIFF, forType: .tiff); monitor.poll()
check(imageCaptures.last == .image(tiffImage), "capture TIFF-only clipboard")
check(monitor.copy(restoredImages.history.entries[0].content), "copy persisted image")
monitor.poll()
check(imageCaptures.count == 2, "suppress own image copy")
check(pasteboard.data(forType: .png) == image.pngData && pasteboard.data(forType: .tiff) != nil,
      "publish PNG and TIFF for paste compatibility")
check(NSImage(pasteboard: pasteboard) != nil, "native AppKit consumer can read copied image")
monitor.paused = true
pasteboard.clearContents(); pasteboard.setData(rawPNG, forType: .png)
monitor.poll(); monitor.paused = false; monitor.poll()
check(imageCaptures.count == 2, "do not capture paused images")
pasteboard.clearContents(); pasteboard.setData(rawPNG, forType: .png)
pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
monitor.poll()
check(imageCaptures.count == 2, "respect concealed image marker")
pasteboard.clearContents(); pasteboard.setData(Data("invalid".utf8), forType: .png); monitor.poll()
check(imageCaptures.count == 2, "ignore malformed clipboard image")

try imageStore.record("evict image", limit: 1)
check(!FileManager.default.fileExists(atPath: imageFile.path), "remove image file when evicted")
try imageStore.record(.image(image), limit: 200)
try imageStore.clear()
let afterClear = try HistoryStore(url: imageIndex, limit: 200)
check(afterClear.history.entries.isEmpty && !FileManager.default.fileExists(atPath: imageFile.path), "clear deletes image assets and survives restart")
try imageStore.record(.image(image), limit: 200)
try Data("damaged PNG".utf8).write(to: imageFile)
do { _ = try HistoryStore(url: imageIndex, limit: 200); fatalError("damaged image should be reported") }
catch { checks += 1 }

let legacyIndex = directory.appendingPathComponent("legacy.json")
let legacyID = UUID()
let legacy = try JSONSerialization.data(withJSONObject: ["entries": [[
    "id": legacyID.uuidString, "text": "旧版文本", "copiedAt": 0
]]])
try legacy.write(to: legacyIndex)
let legacyStore = try HistoryStore(url: legacyIndex, limit: 200)
check(legacyStore.history.entries[0].text == "旧版文本" && legacyStore.history.entries[0].id == legacyID,
      "load original text-only index without loss")
try legacyStore.record(.image(image), limit: 200)
let migrated = try HistoryStore(url: legacyIndex, limit: 200)
check(migrated.history.entries.count == 2 && migrated.history.entries[1].text == "旧版文本", "preserve old text when adding first image")

func noisyPNG(width: Int, height: Int, seed: UInt32) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    var state = seed
    for index in 0..<(bitmap.bytesPerRow * height) {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        bitmap.bitmapData![index] = UInt8(truncatingIfNeeded: state >> 24)
    }
    return bitmap.representation(using: .png, properties: [:])!
}
check(ClipboardImage(data: noisyPNG(width: 1400, height: 1400, seed: 10)) == nil,
      "reject encoded image above per-image byte limit")
let quotaIndex = directory.appendingPathComponent("quota/history.json")
let quotaStore = try HistoryStore(url: quotaIndex, limit: 200)
var oldestDigest = ""
for seed in UInt32(1)...5 {
    let noise = ClipboardImage(data: noisyPNG(width: 1280, height: 1280, seed: seed))!
    if seed == 1 { oldestDigest = noise.digest }
    try quotaStore.record(.image(noise), limit: 200)
}
check(quotaStore.history.entries.count == 4, "image bytes enforce shared total capacity")
check(quotaStore.history.entries.reduce(0) { $0 + $1.content.byteCount } <= History.maximumTotalBytes,
      "bound combined image/text payload")
let quotaAssets = quotaIndex.deletingLastPathComponent().appendingPathComponent("images")
check(!FileManager.default.fileExists(atPath: quotaAssets.appendingPathComponent(oldestDigest + ".png").path),
      "byte-limit eviction deletes oldest PNG asset")
let restoredQuota = try HistoryStore(url: quotaIndex, limit: 200)
check(restoredQuota.history.entries == quotaStore.history.entries, "restore image history at capacity")

let suite = "ClipboardTests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let settings = Settings(defaults: defaults)
check(settings.limit == 200 && settings.shortcut == .default, "default settings")
settings.limit = 50; settings.paused = true
settings.shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey), keyName: "C")
let restored = Settings(defaults: defaults)
check(restored.limit == 50 && restored.paused && restored.shortcut == settings.shortcut, "persist settings independently")
defaults.set(-1, forKey: "historyLimit")
check(Settings(defaults: defaults).limit == 200, "normalize invalid capacity")
check(!Shortcut(keyCode: 55, modifiers: UInt32(cmdKey), keyName: "Command").isValid, "reject modifier-only shortcuts")
check(!Shortcut(keyCode: 9, modifiers: 0, keyName: "V").isValid, "require modifier")
final class FakeHotKeyBackend: HotKeyBackend {
    var status: OSStatus = noErr
    var registrations = 0
    var unregistrations = 0
    func register(keyCode: UInt32, modifiers: UInt32, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?) {
        registrations += 1
        return (status, status == noErr ? EventHotKeyRef(bitPattern: registrations) : nil)
    }
    func unregister(_ reference: EventHotKeyRef) { unregistrations += 1 }
}
let backend = FakeHotKeyBackend()
let hotKey = GlobalHotKey(backend: backend)
check(hotKey.register() == noErr, "install hotkey handler")
check(hotKey.register() == noErr && backend.registrations == 1, "same hotkey registration is idempotent")
backend.status = OSStatus(eventHotKeyExistsErr)
check(hotKey.register(keyCode: 8, modifiers: UInt32(controlKey)) != noErr, "report conflicting replacement")
check(backend.unregistrations == 0, "keep old hotkey when replacement fails")
backend.status = noErr
check(hotKey.register(keyCode: 8, modifiers: UInt32(controlKey)) == noErr && backend.unregistrations == 1,
      "replace hotkey only after successful registration")
hotKey.unregister()
check(backend.unregistrations == 2, "release registered shortcut")
final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var nextStatus: SMAppService.Status = .enabled
    var failure: Error?
    var registrations = 0
    var unregistrations = 0
    func register() throws {
        registrations += 1
        if let failure { throw failure }
        status = nextStatus
    }
    func unregister() throws {
        unregistrations += 1
        if let failure { throw failure }
        status = .notRegistered
    }
}
let loginService = FakeLoginItemService()
let login = LoginItemController(service: loginService)
check(!login.isRequested && loginService.registrations == 0, "reading login status does not enable startup")
login.setEnabled(true)
check(login.status == .enabled && login.isRequested, "enable login item")
login.setEnabled(true)
check(loginService.registrations == 1, "do not register an enabled login item again")
loginService.failure = CocoaError(.fileWriteNoPermission)
login.setEnabled(false)
check(login.isRequested && login.errorMessage != nil, "failed disable preserves actual login status and reports error")
loginService.failure = nil
login.setEnabled(false)
check(!login.isRequested && login.errorMessage == nil, "disable login item and clear previous error")
loginService.failure = CocoaError(.fileReadNoPermission)
login.setEnabled(true)
check(!login.isRequested && login.errorMessage != nil, "failed enable leaves startup off")
loginService.failure = nil
loginService.nextStatus = .requiresApproval
login.setEnabled(true)
check(login.isRequested && login.statusText.contains("批准"), "pending login approval is not presented as enabled")
login.setEnabled(false)
check(login.status == .notRegistered, "cancel pending login approval")
loginService.status = .enabled
login.refresh()
check(login.isRequested, "refresh changes made in system settings")
loginService.status = .notFound
login.refresh()
check(!login.isRequested && login.statusText.contains("Clipboard.app"), "explain missing application")
let snippetURL = directory.appendingPathComponent("saved/snippets.json")
let snippets = try SnippetStore(url: snippetURL)
let snippetText = "  常用正文\n第二行 🐈  "
let savedSnippet = try snippets.save(title: " 问候 ", text: snippetText)
check(savedSnippet.title == "问候" && savedSnippet.text == snippetText, "trim snippet name and preserve full text")
check(savedSnippet.matches("问候") && savedSnippet.matches("第二行"), "search snippet name and content")
let restoredCommon = try SnippetStore(url: snippetURL)
check(restoredCommon.snippets == snippets.snippets, "restore common text after restart")
let snippetPermissions = try FileManager.default.attributesOfItem(atPath: snippetURL.path)
check((snippetPermissions[.posixPermissions] as? NSNumber)?.intValue == 0o600, "common text files are private")
let editedSnippet = try snippets.save(id: savedSnippet.id, title: "新名称", text: "修改后的文本")
check(snippets.snippets.count == 1 && editedSnippet.id == savedSnippet.id && snippets.snippets[0].text == "修改后的文本",
      "edit common text without creating duplicate identity")
let autoTitle = try snippets.save(title: "", text: "自动名称\n正文")
check(autoTitle.title == "自动名称", "derive name when optional title is empty")
for invalid in [" \n", String(repeating: "x", count: History.maximumTextBytes + 1)] {
    let before = snippets.snippets
    do { _ = try snippets.save(title: "错误输入", text: invalid); fatalError("invalid snippet should fail") }
    catch { check(snippets.snippets == before, "invalid common text leaves existing data intact") }
}
try store.clear()
let commonAfterClear = try SnippetStore(url: snippetURL)
check(commonAfterClear.snippets.count == 2, "clearing history preserves common text")
try snippets.delete(id: savedSnippet.id)
let commonAfterDelete = try SnippetStore(url: snippetURL)
check(commonAfterDelete.snippets == [autoTitle], "delete common text and persist deletion")
let blockedDirectory = directory.appendingPathComponent("blocked-snippets")
try Data("not a directory".utf8).write(to: blockedDirectory)
let blockedSnippets = try SnippetStore(url: blockedDirectory.appendingPathComponent("snippets.json"))
do { _ = try blockedSnippets.save(title: "test", text: "test"); fatalError("blocked write should fail") }
catch { check(blockedSnippets.snippets.isEmpty, "failed disk save does not mutate common text") }
try Data("broken common text index".utf8).write(to: snippetURL)
do { _ = try SnippetStore(url: snippetURL); fatalError("corrupt snippet file should fail") }
catch {
    let corruptCommon = try Data(contentsOf: snippetURL)
    check(corruptCommon == Data("broken common text index".utf8), "preserve corrupt common text file")
}
print("PASS: \(checks) history, persistence, clipboard, common text, settings, login item and hotkey checks")
