import Foundation

/// RFC 4648 Base32，无填充。只服务于「恢复码」这一个用途。
///
/// 为什么不用 Base64：恢复码是要**人抄写**的。Base64 里 `l/I/1`、`O/0` 长得一样，
/// 大小写还有意义 —— 抄错一个字符，密码库就永久打不开，而用户不会知道是哪一个字符错了。
/// Base32 的字母表（A-Z2-7）刻意去掉了 `0/1/8/9`，且大小写不敏感。
public enum Base32 {

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// 编码后每 4 个字符插一个 `-`。纯粹为了抄写时不串行，解码会忽略它。
    public static func encode(_ data: Data, grouped: Bool = true) -> String {
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            out.append(alphabet[(buffer << (5 - bits)) & 0x1F])
        }
        guard grouped else { return out }
        return stride(from: 0, to: out.count, by: 4).map {
            let start = out.index(out.startIndex, offsetBy: $0)
            let end = out.index(start, offsetBy: min(4, out.count - $0))
            return String(out[start..<end])
        }.joined(separator: "-")
    }

    /// 解码。忽略分隔符和大小写，并且**把常见的手抄错误纠正回来** ——
    /// 用户从纸上抄回来时把 `O` 写成 `0`、`I`/`l` 写成 `1` 是必然会发生的，
    /// 而这些字符本来就不在字母表里，不纠正的话只能报「恢复码无效」，
    /// 用户完全无从下手。
    public static func decode(_ text: String) -> Data? {
        var buffer = 0
        var bits = 0
        var out = Data()
        for raw in text.uppercased() {
            let ch: Character
            switch raw {
            case "-", " ", "\n", "\t", "\r": continue
            // `0` 和 `1` 不是合法的 base32 字符，所以出现在这里只可能是手抄
            // `O` 和 `I` 时写错了 —— 纠正它是安全的，不存在歧义。
            case "0": ch = "O"
            case "1": ch = "I"
            default: ch = raw
            }
            guard let index = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return out
    }
}
