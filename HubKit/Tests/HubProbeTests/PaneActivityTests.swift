import XCTest
@testable import HubProbe

/// 判断一个会话是不是真停了。
///
/// 这是整套盯梢里唯一容易写错、而且**写错了不会报错只会静默失灵**的部分。
/// bash 版在这上面栽过两次，两次都是实机上被用户先发现的：
/// 一次把 `shell` 当成在干活（停了 20 分钟没催到），
/// 一次在用户打字时把追问拼到了他那句后面。
final class PaneActivityTests: XCTestCase {

    // MARK: - 转圈检测

    /// 本机真实画面。
    func testDetectsTheSpinnerLine() {
        let pane = """
          ⏺ 继续。先把 T31 台账补齐，然后按训练包逐项推进：

            Running 1 shell command…

          ✻ Boondoggling… (17s · ↓ 201 tokens)
        """
        XCTAssertTrue(PaneActivity.isWorking(pane: pane))
    }

    /// 分钟级的计时也要认。
    func testDetectsLongRunningSpinner() {
        XCTAssertTrue(PaneActivity.isWorking(pane: "✽ Wandering… (39m 48s · ↓ 35.8k tokens)"))
    }

    /// **不能去匹配那些动词和符号。**
    ///
    /// Wandering / Boondoggling / ✻ / ✽ / ✳ 是一份永远补不完的名单，
    /// 漏一个就是一次误催。稳定的特征是 `(数字s · ` 这个计时格式。
    func testRecognizesUnfamiliarSpinnerWords() {
        XCTAssertTrue(PaneActivity.isWorking(pane: "✶ Flibbertigibbeting… (3s · ↓ 12 tokens)"))
        XCTAssertTrue(PaneActivity.isWorking(pane: "* Doing Something New… (1m 2s · ↑ 5 tokens)"))
    }

    /// 空在提示符上 = 没在干活。
    func testIdlePaneIsNotWorking() {
        let pane = """
        ❯
        ─────────────────────────────────────
          # dev @ MacBook-Pro in ~/code [02:35:47]
          ⏵⏵ bypass permissions on · 1 shell
        """
        XCTAssertFalse(PaneActivity.isWorking(pane: pane))
    }

    /// 历史输出里的括号数字不能误判成转圈。
    func testPlainNumbersDoNotLookLikeASpinner() {
        XCTAssertFalse(PaneActivity.isWorking(pane: "改了 12 行 (共 30s 的构建)"))
        XCTAssertFalse(PaneActivity.isWorking(pane: "耗时 (3s)"))
    }

    // MARK: - 输入框草稿

    /// **用户正在打字时绝不能发。**
    ///
    /// send-keys 往当前输入位置敲字，会直接拼到他那句后面。
    /// 实机上真发生过：把用户的「你该操作代码的操作代码…」和追问接成了一句。
    func testDetectsUserDraft() {
        let pane = """
        ⏺ 上一轮的输出
        ❯ 你既可以开发 也可以训练
        ─────────────────────────────────────
        """
        XCTAssertEqual(PaneActivity.draft(pane: pane), "你既可以开发 也可以训练")
    }

    /// 取最后一个 `❯` —— 上方历史消息里也有，只有最后那个是输入框。
    func testUsesTheLastPromptNotTheHistory() {
        let pane = """
        ❯ 这是十分钟前发过的一句话
        ⏺ 回复
        ❯
        """
        XCTAssertNil(PaneActivity.draft(pane: pane), "历史里的 ❯ 不算草稿")
    }

    func testEmptyPromptIsNotADraft() {
        XCTAssertNil(PaneActivity.draft(pane: "❯ "))
        XCTAssertNil(PaneActivity.draft(pane: "❯"))
    }

    /// **排队提示不是草稿。**
    ///
    /// 有消息排队时输入框位置会显示 "Press up to edit queued messages"。
    /// 把它当成草稿的话，一旦有排队盯梢就再也不敢发言了 ——
    /// 而排队恰恰说明它正忙，忙完就会读，这时候补一条完全没问题。
    func testQueuedMessageHintIsNotADraft() {
        XCTAssertNil(PaneActivity.draft(pane: "❯ Press up to edit queued messages"))
    }

    func testNoPromptAtAll() {
        XCTAssertNil(PaneActivity.draft(pane: "什么都没有"))
    }

    // MARK: - 综合判断

    /// `busy` 是唯一能单独证明"在干活"的状态。
    func testBusyIsLeftAlone() {
        XCTAssertNotNil(PaneActivity.doNotDisturb(status: "busy", pane: "❯"))
    }

    /// **`shell` 不等于在干活。**
    ///
    /// 它表示"挂着一个后台 shell"，和 Claude 自己在不在思考无关。
    /// 实机上它空在提示符等输入时状态就是 shell —— bash 版把它当成在干活，
    /// 于是停了 20 分钟一次都没催到。这条测试就是那次事故的护栏。
    func testShellStatusWithIdleScreenCanBeInterrupted() {
        let idle = """
        ❯
        ─────────────────────────────────────
          ⏵⏵ bypass permissions on · 1 shell
        """
        XCTAssertNil(
            PaneActivity.doNotDisturb(status: "shell", pane: idle),
            "shell + 屏幕没转圈 + 输入框空着 = 真的停了，必须能催"
        )
    }

    /// `shell` 但屏幕在转圈 —— 那是真在跑命令，别打扰。
    func testShellStatusWithSpinnerIsLeftAlone() {
        XCTAssertNotNil(
            PaneActivity.doNotDisturb(status: "shell", pane: "✻ Running… (8s · ↓ 3 tokens)")
        )
    }

    func testDraftBlocksTheNudge() {
        XCTAssertNotNil(PaneActivity.doNotDisturb(status: "idle", pane: "❯ 我正在打字"))
    }

    func testTrulyIdleCanBeNudged() {
        XCTAssertNil(PaneActivity.doNotDisturb(status: "idle", pane: "❯"))
    }

    /// 状态读不出来但屏幕明显停着 —— 可以催。
    ///
    /// 状态文件缺失的常见原因是刚 resume 换了 pid，那时候屏幕是可信的。
    func testMissingStatusFallsBackToTheScreen() {
        XCTAssertNil(PaneActivity.doNotDisturb(status: nil, pane: "❯"))
        XCTAssertNotNil(
            PaneActivity.doNotDisturb(status: nil, pane: "✻ Thinking… (2s · ↓ 1 tokens)")
        )
    }
}
