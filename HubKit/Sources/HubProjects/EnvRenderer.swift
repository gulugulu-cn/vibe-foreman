import Foundation

/// 把几组密钥渲染成一个 `.env` 文件的正文。**纯函数。**
///
/// ## 为什么值一律用单引号
///
/// 这个文件有三个消费者：`source` 它的 shell、node 的 dotenv、python-dotenv。
/// 三家对引号的处理只有一处交集 —— **单引号内不做任何展开**：
/// sh 的单引号里 `$`、反引号、`\`、`#` 全是字面量；两个 dotenv 实现对单引号值也不展开。
/// 双引号在三家手里的行为各不相同，用它必然有一家读错。
///
/// 前缀一律加 `export`：这样不带 `set -a` 直接 `source` 也能拿到变量，
/// 而两个 dotenv 实现都会识别并剥掉这个前缀。纯赚。
///
/// ## 多行值（PEM 私钥）用字面换行，不要写 `\n`
///
/// 这是最常见的那个坑：`\n` 只有 dotenv 的**双引号**下才会被还原成换行，
/// 而 sh 的双引号**不还原**。写字面换行反而三家都对。
///
/// ## 含单引号的值：改写成 `KEY_B64`
///
/// sh 里要写成 `'\''`（关引号 → 转义的单引号 → 开引号），
/// 而 node dotenv 的正则是 `'([^']*)'`，遇到第一个 `'` 就截断，**拿到的是残值**。
/// 两者没有共同解。
///
/// 所以含单引号的值不写进 `.env`，改写 `KEY_B64='<base64>'` 并在文件头说明还原方法。
/// 飞书 / 领星 / OpenAI 的密钥全是 base64url 或十六进制，单引号出现概率接近 0 ——
/// 为这 0.1% 牺牲 99.9% 的可读性是错的，但**静默写出一个残值更错**，
/// 因为那会表现成「密钥是对的但接口就是不通」。
///
/// ## 文件里绝不写时间戳
///
/// 有时间戳，「内容没变就不写」这个判断永远失效，于是每次启动都重写一遍密钥文件，
/// 而每次重写都是一次权限回归的窗口（`.atomic` 会换 inode）。
/// 同 `HookInstaller` 那句「`.sortedKeys` 不是审美，是幂等的前提」。
public enum EnvRenderer {

    public static func render(
        groups: [SecretGroup],
        projectName: String,
        filePath: String
    ) -> String {
        var out = header(projectName: projectName, filePath: filePath)

        // 排序是幂等的前提：顺序随内存布局漂的话，改一条键会让整个文件全变，
        // 「内容零差异就不写」也就永远命不中。
        let sorted = groups.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        for group in sorted {
            out += "\n# —— \(group.name) ——\n"
            if !group.note.isEmpty {
                out += comment(group.note)
            }
            for entry in group.entries.sorted(by: { $0.key < $1.key }) {
                out += render(entry: entry)
            }
        }
        return out
    }

    // MARK: - 零件

    static func render(entry: SecretEntry) -> String {
        var out = ""
        if !entry.note.isEmpty { out += comment(entry.note) }

        guard SecretEntry.isValidKey(entry.key) else {
            return out + comment("跳过 \(entry.key)：不是合法的环境变量名")
        }
        guard !entry.isUnwritable else {
            return out + comment("跳过 \(entry.key)：值里含 NUL 字节，环境变量装不下")
        }
        if entry.needsBase64 {
            let encoded = Data(entry.value.utf8).base64EncodedString()
            out += comment("\(entry.key) 的值含单引号，见文件头说明")
            out += "export \(entry.key)_B64='\(encoded)'\n"
            return out
        }
        out += "export \(entry.key)='\(entry.value)'\n"
        return out
    }

    /// 备注可能是多行的，每一行都得自己带 `#`，否则第二行会被 shell 当成命令。
    static func comment(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "# \($0)\n" }.joined()
    }

    static func header(projectName: String, filePath: String) -> String {
        """
        # Vibe Foreman 生成 —— 不要手改，下次同步会原样覆盖。
        # 项目：\(projectName)
        #
        # 这个文件里是明文密钥。不要提交，不要复制进项目目录。
        #
        # 用法（写在需要它的那条命令里，不要写进 shell 的 rc）：
        #   set -a; source '\(filePath)'; set +a; <你的命令>
        #
        # 值一律用单引号包裹 —— 单引号内 shell 不做任何展开，dotenv 也不展开，
        # 这是 shell / node dotenv / python-dotenv 三家唯一的共同解。
        # 多行值（比如 PEM 私钥）用字面换行，不是 \\n。
        #
        # 名字以 _B64 结尾的，原值里含单引号，没法同时兼容三家，已经 base64 过：
        #   echo "$XXX_B64" | base64 -d

        """
    }
}
