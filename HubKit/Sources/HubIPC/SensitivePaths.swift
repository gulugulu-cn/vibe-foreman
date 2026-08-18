import Foundation

/// Hub 自己存密钥的那几个位置。
///
/// ## 为什么常量抄在这里而不是从 HubProjects 引
///
/// `HubIPC` 刻意不依赖 `HubProjects`（见 `Package.swift` 的注释）：
/// `hubctl` 每次工具调用都要跑一遍，必须小而快，多链一个库就多一份启动开销。
///
/// 抄常量的代价是会漂。所以 `HubUITests/SensitivePathsAgreementTests`
/// 把两边的真实路径拿来对了一遍 —— 那个测试目录同时看得见两个模块。
/// 改了 `EnvMaterializer.defaultRoot` 或者哪个 `.dat` 的名字，那条测试会红。
public enum SensitivePaths {

    /// 相对家目录的前缀。
    static let prefixes = [
        // 共用密钥物化出来的 .env（对应 EnvMaterializer.defaultRoot）
        ".vibe-foreman/env/",
        // 两个库的密文本体（对应 SharedSecretStore / CredentialStore 的 defaultURL）
        "Library/Application Support/claude-hub/shared-secrets.dat",
        "Library/Application Support/claude-hub/credentials.dat",
    ]

    /// 这段文本里有没有指向密钥文件的路径。
    ///
    /// 用后缀匹配而不是拼上真实家目录再比：`~` 有没有展开、有没有走软链、
    /// 是不是 `/Users/xxx` 还是 `/private/...`，取决于调用方怎么写的，
    /// 一个都不能假设。而这几个前缀本身已经足够独特，误伤概率可以忽略。
    public static func matches(_ text: String) -> Bool {
        prefixes.contains { text.contains($0) }
    }
}
