import Foundation

struct AppVersion {
    let version: String
    let build: String
    let channel: String
    let revision: String
    let builtAt: String

    static var current: AppVersion {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppVersion(
            version: info["CFBundleShortVersionString"] as? String ?? "未知",
            build: info["CFBundleVersion"] as? String ?? "未知",
            channel: info["ClipboardBuildChannel"] as? String ?? "local",
            revision: info["ClipboardSourceRevision"] as? String ?? "未知",
            builtAt: info["ClipboardBuildDate"] as? String ?? "未知"
        )
    }

    var displayName: String { "\(version)（Build \(build)）" }
    var sourceDescription: String {
        let channelName = channel == "local" ? "本机构建" : channel
        return "\(channelName) · \(revision) · \(builtAt)"
    }
    var updateStatus: String {
        "此版本尚未配置在线更新源，无法判断是否有更新。"
    }
}
