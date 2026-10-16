import XCTest
@testable import MacDesktopNotify

final class BlocksDSLTests: SettingsIsolatedTestCase {
    private var manager: NotificationManager = NotificationManager()
    private lazy var router: APIRouter = APIRouter(manager: manager)

    // MARK: - Renderer: heading / list parsing

    func testHeadingParsesWithLevel() {
        let blocks = MarkdownRenderer.parse("## 部署完成")
        guard case .heading(let text, let level)? = blocks.first else {
            return XCTFail("应为 heading 块，实得 \(blocks)")
        }
        XCTAssertEqual(String(text.characters), "部署完成")
        XCTAssertEqual(level, 2)
    }

    func testSevenHashesIsProseNotHeading() {
        // 7 个 # 不匹配 1–6 的模式，是 prose 而不是 heading。
        let blocks = MarkdownRenderer.parse("####### 七级")
        guard case .prose? = blocks.first else {
            return XCTFail("7 个 # 不是 heading，是 prose")
        }
    }

    func testHeadingRequiresSpaceAfterMarker() {
        // "#tag" 不是 heading——井号后必须跟空白。
        let blocks = MarkdownRenderer.parse("#tag")
        guard case .prose? = blocks.first else {
            return XCTFail("#tag 是 prose，不是 heading")
        }
    }

    func testUnorderedListParses() {
        let blocks = MarkdownRenderer.parse("- 下载制品\n- 跑测试\n- 上线")
        guard case .list(let items, let ordered)? = blocks.first else {
            return XCTFail("应为 list 块，实得 \(blocks)")
        }
        XCTAssertEqual(items.map { String($0.characters) }, ["下载制品", "跑测试", "上线"])
        XCTAssertFalse(ordered)
    }

    func testOrderedListParses() {
        let blocks = MarkdownRenderer.parse("1. 构建\n2. 测试\n3. 发布")
        guard case .list(let items, let ordered)? = blocks.first else {
            return XCTFail("应为 ordered list 块，实得 \(blocks)")
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(ordered)
    }

    func testBlankLineSeparatesParagraphsAndLists() {
        let blocks = MarkdownRenderer.parse("intro\n- a\n- b\n\npara\n## T\n- c")
        // intro | list(a,b) | para | heading | list(c)
        XCTAssertEqual(blocks.count, 5, "实得 \(blocks)")
        guard case .prose = blocks[0],
              case .list(let items, _) = blocks[1] else {
            return XCTFail("前两块应为 prose+list")
        }
        XCTAssertEqual(items.map { String($0.characters) }, ["a", "b"])
        guard case .heading(_, let level) = blocks[3] else {
            return XCTFail("第 4 块应为 heading")
        }
        XCTAssertEqual(level, 2)
    }

    func testProseAfterListWithoutBlankLineEndsList() {
        let blocks = MarkdownRenderer.parse("- a\n普通段落")
        // 紧跟的非列表文本结束列表，成为新段落。
        guard case .list(let items, _)? = blocks.first,
              case .prose? = blocks.last else {
            return XCTFail("应为 list + prose，实得 \(blocks)")
        }
        XCTAssertEqual(items.map { String($0.characters) }, ["a"])
    }

    func testMixedMarkersSplitIntoTwoLists() {
        let blocks = MarkdownRenderer.parse("- a\n1. b")
        // 标记翻转不合并成一个混合列表：拆成两个 list 段。
        XCTAssertEqual(blocks.count, 2)
        guard case .list(_, let o1) = blocks[0], case .list(_, let o2) = blocks[1] else {
            return XCTFail("应为两个独立 list")
        }
        XCTAssertFalse(o1)
        XCTAssertTrue(o2)
    }

    func testHeadingAndListInsideCodeFenceAreCode() {
        let blocks = MarkdownRenderer.parse("```\n## not a heading\n- not a list\n```")
        XCTAssertEqual(blocks, [.code("## not a heading\n- not a list")])
    }

    // MARK: - 反糖：BlockDTO → Markdown body

    private func deSugar(_ json: String) -> String? {
        let dtos = try! JSONDecoder().decode([PushValidator.BlockDTO].self, from: Data(json.utf8))
        return PushValidator.body(fromBlocks: dtos)
    }

    func testDeSugarAllFourBlockTypes() {
        let body = deSugar(#"[{"type":"heading","text":"部署报告","level":2},{"type":"text","text":"全部通过"},{"type":"list","items":["a","b"],"ordered":false},{"type":"code","text":"exit 0\n"}]"#)
        XCTAssertEqual(body, "## 部署报告\n\n全部通过\n\n- a\n- b\n\n```\nexit 0\n```")
    }

    func testDeSugarOrderedList() {
        let body = deSugar(#"[{"type":"list","items":["一","二"],"ordered":true}]"#)
        XCTAssertEqual(body, "1. 一\n2. 二")
    }

    func testDeSugarClampsHeadingLevel() {
        XCTAssertEqual(deSugar(#"[{"type":"heading","text":"T","level":99}]"#), "###### T")
        XCTAssertEqual(deSugar(#"[{"type":"heading","text":"T","level":0}]"#), "# T")
        XCTAssertEqual(deSugar(#"[{"type":"heading","text":"T"}]"#), "# T")
    }

    func testDeSugarUnknownTypeIsDropped() {
        // 未知 type 丢弃，不拒绝（沿 actions 的 truncate-never-reject 先例）。
        XCTAssertEqual(deSugar(#"[{"type":"table","text":"x"},{"type":"text","text":"保留"}]"#), "保留")
    }

    func testDeSugarEmptyEntriesAreDropped() {
        XCTAssertNil(deSugar(#"[{"type":"text","text":"  "},{"type":"code","text":"\n"},{"type":"list","items":[""," "]},{"type":"heading","text":""}]"#))
    }

    // MARK: - HTTP / WS 两门端到端 + 跨门一致性

    /// 同一份 blocks 载荷，HTTP 与 WS 两个 JSON 门的产物必须一致——
    /// actions 跨门对拍的 blocks 版：分叉反糖共用 `body(fromBlocks:)`，
    /// 防止某个门长出自己的规则。
    func testPushBlocksAcrossHTTPAndWSIngress() async throws {
        let blocks: [[String: Any]] = [
            ["type": "heading", "text": "报告", "level": 2],
            ["type": "text", "text": "全部通过"],
            ["type": "list", "items": ["单测", "集成"], "ordered": true],
            ["type": "code", "text": "exit 0"]
        ]
        let http = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: try JSONSerialization.data(withJSONObject: ["title": "部署", "blocks": blocks])))
        XCTAssertEqual(http.status, 200)

        var wsPayload: [String: Any] = ["op": "push", "title": "部署"]
        wsPayload["blocks"] = blocks
        let ws = await router.handleWSCommand(try JSONSerialization.data(withJSONObject: wsPayload))
        let frame = try JSONSerialization.jsonObject(with: ws) as! [String: Any]
        XCTAssertEqual(frame["ok"] as? Bool, true)

        // 两门产物一致：模型里只有一份规范 Markdown。
        let bodies = manager.history.map(\.bodyMarkdown)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertEqual(bodies[0], "## 报告\n\n全部通过\n\n1. 单测\n2. 集成\n\n```\nexit 0\n```")
        // 且能被 renderer 还原成 4 个块。
        XCTAssertEqual(MarkdownRenderer.parse(bodies[0]).count, 4)
    }

    func testBlocksStillFlowThroughBodyCap() throws {
        // 反糖结果仍受 5000 上限约束。
        let long = String(repeating: "字", count: 6000)
        let n = try PushValidator.makeNotification(
            title: "t",
            body: deSugar(#"[{"type":"text","text":"\#(long)"}]"#),
            urgencyRaw: nil, timeout: nil, group: nil, actions: []).get()
        XCTAssertEqual(n.bodyMarkdown.count, 5000)
    }
}
