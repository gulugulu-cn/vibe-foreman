import XCTest
@testable import HubIPC

final class AgentPromptParsingTests: XCTestCase {

    // MARK: - AskUserQuestion

    func testSingleChoiceQuestionParsesFully() {
        let json = """
        {"questions":[{"question":"用哪种方案？","header":"方案","multiSelect":false,
        "options":[{"label":"方案 A","description":"稳"},{"label":"方案 B"}]}]}
        """
        guard case .questions(let questions)? = AgentPromptPayload.parse(
            toolName: "AskUserQuestion", inputJSON: json
        ), let question = questions.first
        else { return XCTFail("单选题必须解析成 .questions") }

        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(question.question, "用哪种方案？")
        XCTAssertEqual(question.header, "方案")
        XCTAssertFalse(question.multiSelect)
        XCTAssertEqual(question.options.map(\.label), ["方案 A", "方案 B"])
        XCTAssertEqual(question.options.first?.description, "稳")
        XCTAssertNil(question.options.last?.description)
    }

    /// 多选题在岛上是勾选 + 提交，必须保留 multiSelect 标记。
    func testMultiSelectParsesWithFlag() {
        let json = """
        {"questions":[{"question":"要哪些？","multiSelect":true,
        "options":[{"label":"A"},{"label":"B"}]}]}
        """
        guard case .questions(let questions)? = AgentPromptPayload.parse(
            toolName: "AskUserQuestion", inputJSON: json
        ) else { return XCTFail("多选题必须解析成 .questions") }
        XCTAssertEqual(questions.first?.multiSelect, true)
    }

    /// 多题表单（截图里那种带 tab + Submit 的）要完整解析，岛上逐题作答。
    func testMultipleQuestionsParseInOrder() {
        let json = """
        {"questions":[
        {"question":"一","header":"压测方式","options":[{"label":"A"}]},
        {"question":"二","header":"回收策略","options":[{"label":"B"}],"multiSelect":true}]}
        """
        guard case .questions(let questions)? = AgentPromptPayload.parse(
            toolName: "AskUserQuestion", inputJSON: json
        ) else { return XCTFail("多题必须解析成 .questions") }
        XCTAssertEqual(questions.map(\.answerKey), ["压测方式", "回收策略"])
        XCTAssertEqual(questions.map(\.multiSelect), [false, true])
    }

    /// 任何一题缺选项，整组都答不完整，必须降级去终端。
    func testQuestionSetWithOneOptionlessQuestionDegrades() {
        let json = """
        {"questions":[
        {"question":"一","options":[{"label":"A"}]},
        {"question":"二","options":[]}]}
        """
        guard case .complex? = AgentPromptPayload.parse(
            toolName: "AskUserQuestion", inputJSON: json
        ) else { return XCTFail("缺选项的题组必须降级成 .complex") }
    }

    // MARK: - EnterPlanMode

    /// 请求进入计划模式：input 是空对象，甚至可能不带 —— 都必须弹卡。
    func testEnterPlanModeParsesEvenWithoutInput() {
        guard case .enterPlan? = AgentPromptPayload.parse(
            toolName: "EnterPlanMode", inputJSON: "{}"
        ) else { return XCTFail("EnterPlanMode 必须解析成 .enterPlan") }
        guard case .enterPlan? = AgentPromptPayload.parse(
            toolName: "EnterPlanMode", inputJSON: nil
        ) else { return XCTFail("没有 input 也必须是 .enterPlan") }
    }

    /// 没有选项的问题在岛上没有可点的东西，只能去终端。
    func testQuestionWithoutOptionsDegradesToComplex() {
        let json = #"{"questions":[{"question":"说说看？","options":[]}]}"#
        guard case .complex? = AgentPromptPayload.parse(
            toolName: "AskUserQuestion", inputJSON: json
        ) else { return XCTFail("无选项必须降级成 .complex") }
    }

    // MARK: - ExitPlanMode

    func testPlanParses() {
        let json = ##"{"plan":"# 计划\n1. 先这样\n2. 再那样"}"##
        guard case .plan(let plan)? = AgentPromptPayload.parse(
            toolName: "ExitPlanMode", inputJSON: json
        ) else { return XCTFail("计划必须解析成 .plan") }
        XCTAssertTrue(plan.contains("先这样"))
    }

    // MARK: - 降级与边界

    /// 旧 hubctl 不带 toolInputJSON（或超长被裁掉）时，**必须仍然弹卡**，
    /// 只是降级成"去终端回答"—— 完全不弹就回到修复前的 bug。
    func testMissingInputDegradesToComplexNotNil() {
        XCTAssertNotNil(AgentPromptPayload.parse(toolName: "AskUserQuestion", inputJSON: nil))
        XCTAssertNotNil(AgentPromptPayload.parse(toolName: "ExitPlanMode", inputJSON: nil))
        guard case .complex? = AgentPromptPayload.parse(
            toolName: "AskUserQuestion", inputJSON: "不是 json"
        ) else { return XCTFail("坏 JSON 必须降级成 .complex") }
    }

    /// 非交互工具绝不能走这条链路 —— 它们归 RiskClassifier 管。
    func testNonInteractiveToolReturnsNil() {
        XCTAssertNil(AgentPromptPayload.parse(toolName: "Bash", inputJSON: #"{"command":"ls"}"#))
        XCTAssertNil(AgentPromptPayload.parse(toolName: "Write", inputJSON: nil))
    }

    // MARK: - HookDecision 的 stdout 输出

    /// 普通 allow 必须什么都不输出 —— 不输出 = 交回 Claude 正常权限流程，
    /// 这是「去终端回答」和超时兜底的实现基础。
    func testPlainAllowEmitsNothing() {
        XCTAssertNil(HookDecision.allow.hookOutputJSON())
        XCTAssertNil(HookDecision(verdict: .allow, explicitAllow: false).hookOutputJSON())
    }

    /// 批准计划要的是真放行：必须显式输出 allow。
    func testExplicitAllowEmitsPermissionDecision() throws {
        let text = try XCTUnwrap(
            HookDecision(verdict: .allow, explicitAllow: true).hookOutputJSON()
        )
        XCTAssertTrue(text.contains(#""permissionDecision":"allow""#))
        XCTAssertTrue(text.contains(#""hookEventName":"PreToolUse""#))
    }

    func testDenyEmitsReason() throws {
        let text = try XCTUnwrap(
            HookDecision(verdict: .deny, reason: "用户已在 Claude Hub 上选择：方案 A").hookOutputJSON()
        )
        XCTAssertTrue(text.contains(#""permissionDecision":"deny""#))
        XCTAssertTrue(text.contains("方案 A"))
    }

    /// ask 是既有语义（交回 Claude 权限流程的显式形式），行为不能被这次重构改掉。
    func testAskStillEmits() throws {
        let text = try XCTUnwrap(HookDecision(verdict: .ask).hookOutputJSON())
        XCTAssertTrue(text.contains(#""permissionDecision":"ask""#))
    }

    /// 新旧二进制混用：旧端发来的 JSON 没有 explicitAllow，必须能解。
    func testDecisionDecodesWithoutExplicitAllow() throws {
        let legacy = #"{"verdict":"allow"}"#
        let decoded = try JSONDecoder().decode(HookDecision.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.verdict, .allow)
        XCTAssertNil(decoded.explicitAllow)
    }

    /// 事件同理：旧 hubctl 不带 toolInputJSON。
    func testEventDecodesWithoutToolInputJSON() throws {
        let legacy = #"{"kind":"preToolUse","requestId":"r","sessionId":"s","cwd":"/tmp"}"#
        let decoded = try JSONDecoder().decode(HookEvent.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.toolInputJSON)
    }
}
