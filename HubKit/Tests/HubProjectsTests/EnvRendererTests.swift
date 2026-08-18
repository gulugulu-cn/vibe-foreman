import XCTest
@testable import HubProjects

/// 一个刻意严格的 `.env` 解析器，只认我们**承诺**的那个子集：
/// `export KEY='值'`，单引号内直到下一个单引号（可以跨行），`#` 开头是注释。
///
/// 它存在的唯一意义是「用另一套代码把生成的文件读回来」。
/// 拿 `EnvRenderer` 自己的逻辑反解等于什么都没测 —— 转义写错了它也会照样错着解回来。
enum MiniEnvParser {
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            guard line.hasPrefix("export ") else { continue }
            let rest = String(line.dropFirst("export ".count))
            guard let eq = rest.firstIndex(of: "=") else { continue }
            let key = String(rest[rest.startIndex..<eq])
            var tail = String(rest[rest.index(after: eq)...])
            guard tail.hasPrefix("'") else { continue }
            tail.removeFirst()

            if let end = tail.firstIndex(of: "'") {
                out[key] = String(tail[tail.startIndex..<end])
                continue
            }
            // 值跨行了，一直读到收尾的单引号。
            var acc = tail
            while i < lines.count {
                let next = lines[i]
                i += 1
                if let end = next.firstIndex(of: "'") {
                    acc += "\n" + String(next[next.startIndex..<end])
                    break
                }
                acc += "\n" + next
            }
            out[key] = acc
        }
        return out
    }
}

/// `.env` 的生成规则。这一组守的是「写出去的值和用户填进来的值一模一样」——
/// 转义错了不会报错，只会表现成「密钥明明是对的但接口就是不通」，
/// 而那种问题在生产上要查很久。
final class EnvRendererTests: XCTestCase {

    private func rendered(_ pairs: [(String, String)]) -> [String: String] {
        let group = SecretGroup(
            name: "飞书",
            entries: pairs.map { SecretEntry(key: $0.0, value: $0.1) }
        )
        let text = EnvRenderer.render(groups: [group], projectName: "demo", filePath: "/tmp/demo.env")
        return MiniEnvParser.parse(text)
    }

    /// shell 里有特殊含义的字符，在单引号内必须原样活下来。
    func testShellMetacharactersSurviveRoundTrip() {
        let samples: [(String, String)] = [
            ("PLAIN", "abc123"),
            ("WITH_SPACE", "hello world"),
            ("WITH_HASH", "abc#def"),
            ("WITH_EQUALS", "a=b=c"),
            ("WITH_DOLLAR", "$HOME/not-expanded"),
            ("WITH_BACKTICK", "a`whoami`b"),
            ("WITH_BACKSLASH", #"a\nb"#),
            ("WITH_DQUOTE", "say \"hi\""),
            ("PADDED", "  边上有空格  "),
            ("EMPTY", ""),
            ("UNICODE", "密钥值🔑"),
        ]
        let parsed = rendered(samples)
        for (key, value) in samples {
            XCTAssertEqual(parsed[key], value, "\(key) 没有原样还原")
        }
    }

    /// PEM 私钥是多行的。**必须写字面换行，不能写 `\n`** ——
    /// `\n` 只有 dotenv 的双引号下才还原，sh 的双引号不还原，写了就三家都不对。
    func testMultilinePEMKeepsLiteralNewlines() {
        let pem = """
        -----BEGIN PRIVATE KEY-----
        MIIEvQIBADANBgkqhkiG9w0BAQEFAASC
        -----END PRIVATE KEY-----
        """
        XCTAssertEqual(rendered([("PEM", pem)])["PEM"], pem)
    }

    /// 含单引号的值没有能同时兼容 shell 和 dotenv 的写法。
    /// 所以它**不能**以原名出现（那一定是个残值），只能走 `_B64`。
    func testSingleQuoteGoesToBase64() {
        let value = "it's a secret"
        let parsed = rendered([("QUOTED", value)])

        XCTAssertNil(parsed["QUOTED"], "含单引号的值被原样写出去了，dotenv 读到的会是残值")
        guard let encoded = parsed["QUOTED_B64"] else {
            return XCTFail("没有生成 QUOTED_B64")
        }
        XCTAssertEqual(String(data: Data(base64Encoded: encoded)!, encoding: .utf8), value)
    }

    /// 环境变量装不下 NUL，写出去只会得到一个悄悄被截断的值。
    func testNULValueIsSkippedNotTruncated() {
        let parsed = rendered([("BAD", "a\0b")])
        XCTAssertNil(parsed["BAD"])
        XCTAssertNil(parsed["BAD_B64"])
    }

    func testInvalidKeyIsSkipped() {
        for bad in ["2FA_CODE", "has-dash", "has space", ""] {
            let parsed = rendered([(bad, "x")])
            XCTAssertTrue(parsed.isEmpty, "非法的键名 \(bad) 被写出去了")
        }
    }

    /// **幂等的前提。** 输出跟着字典/集合的内存顺序漂的话，
    /// 改一条键会让整个文件全变，`reconcile` 的「内容零差异就不写」就永远命不中，
    /// 于是每次启动都重写一遍密钥文件 —— 而每次重写都是一次权限回归的窗口。
    func testOutputIsStableAcrossRenders() {
        let a = SecretGroup(name: "领星", entries: [
            SecretEntry(key: "B_KEY", value: "2"), SecretEntry(key: "A_KEY", value: "1"),
        ])
        let b = SecretGroup(name: "飞书", entries: [SecretEntry(key: "C_KEY", value: "3")])

        let first = EnvRenderer.render(groups: [a, b], projectName: "p", filePath: "/tmp/p.env")
        let second = EnvRenderer.render(groups: [b, a], projectName: "p", filePath: "/tmp/p.env")
        XCTAssertEqual(first, second, "组的顺序变了输出就变，幂等判断会永远失效")

        // 键也要排序。
        XCTAssertLessThan(
            first.range(of: "A_KEY")!.lowerBound, first.range(of: "B_KEY")!.lowerBound
        )
    }

    /// 文件里出现时间戳就等于每次都「内容变了」。
    func testNoTimestampInOutput() {
        let text = EnvRenderer.render(
            groups: [SecretGroup(name: "x", entries: [SecretEntry(key: "K", value: "v")])],
            projectName: "p", filePath: "/tmp/p.env"
        )
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertFalse(text.contains("\(year)"), "输出里带了时间戳：\n\(text)")
    }

    /// 多行备注的第二行要是没带 `#`，`source` 时会被当成命令执行。
    func testMultilineNoteIsFullyCommented() {
        let entry = SecretEntry(key: "K", value: "v", note: "第一行\nrm -rf /tmp/whatever")
        let text = EnvRenderer.render(entry: entry)
        for line in text.split(separator: "\n") where !line.hasPrefix("export ") {
            XCTAssertTrue(line.hasPrefix("#"), "这一行没被注释掉：\(line)")
        }
    }

    /// 文件头得把「怎么用」和「别提交」说清楚 —— 打开文件的人可能是三个月后的自己。
    func testHeaderCarriesUsageAndWarning() {
        let text = EnvRenderer.render(groups: [], projectName: "demo", filePath: "/tmp/demo.env")
        XCTAssertTrue(text.contains("set -a; source '/tmp/demo.env'; set +a"))
        XCTAssertTrue(text.contains("不要提交"))
        XCTAssertTrue(text.contains("demo"))
    }
}
