import Foundation

/// 一条共用密钥。
public struct SecretEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// 环境变量名。必须过 `SecretEntry.isValidKey`。
    public var key: String
    public var value: String
    public var note: String

    public init(id: UUID = UUID(), key: String, value: String, note: String = "") {
        self.id = id
        self.key = key
        self.value = value
        self.note = note
    }

    /// 环境变量名的合法形状。
    ///
    /// **在界面上就要拦住**，不要等到写文件时才发现 —— 那时候用户已经离开这个页面了，
    /// 而失败的表现是「那个变量就是不生效」，没人会联想到是名字不合法。
    public static func isValidKey(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    /// 值里带单引号或者裸 NUL 的，没法照常写进 `.env`，见 `EnvRenderer`。
    public var needsBase64: Bool { value.contains("'") }
    public var isUnwritable: Bool { value.contains("\0") }
}

/// 一组共用密钥，按平台归。
public struct SecretGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// 飞书 / 领星 / OpenAI…
    public var name: String
    public var note: String
    public var entries: [SecretEntry]

    /// 哪些项目用这一组。元素是 `ProjectKey.key(for:)`。
    ///
    /// 绑定挂在组身上，而不是单独一张 `[组: 项目]` 的表 ——
    /// 这样删掉一个组，它的绑定跟着一起没，不会留下指向空组的悬挂引用。
    /// 单独一张表的话，「删组时忘了清表」是迟早会发生的，而症状是
    /// 物化出来的文件里凭空少了几个变量，查起来毫无头绪。
    public var projectKeys: Set<String>

    public init(
        id: UUID = UUID(), name: String, note: String = "",
        entries: [SecretEntry] = [], projectKeys: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.entries = entries
        self.projectKeys = projectKeys
    }
}

/// 落盘的那个 payload（加密之前的样子）。
public struct SecretVaultData: Codable, Sendable, Equatable {
    public var groups: [SecretGroup]

    public init(groups: [SecretGroup] = []) {
        self.groups = groups
    }

    /// 某个项目该拿到哪几组，按名字排好序。
    public func groups(forProjectKey key: String) -> [SecretGroup] {
        groups.filter { $0.projectKeys.contains(key) }
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    }

    /// 所有被绑定过的项目 key。`reconcile` 用它算「应该存在哪些文件」。
    public var boundProjectKeys: Set<String> {
        groups.reduce(into: Set<String>()) { $0.formUnion($1.projectKeys) }
    }
}
