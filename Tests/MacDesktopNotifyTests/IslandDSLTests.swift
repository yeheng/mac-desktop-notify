import XCTest
@testable import MacDesktopNotify

/// `island` 字段：灵动岛紧凑面（pill / 迷你条 / peek）的状态行由推送携带的
/// 结构化字段驱动。归一化闸与两门一致性同 blocks/actions 同一哲学：
/// truncate, never reject。
final class IslandDSLTests: SettingsIsolatedTestCase {
    private var manager: NotificationManager = NotificationManager()
    private lazy var router: APIRouter = APIRouter(manager: manager)

    private func decodeIsland(_ json: String) -> PushValidator.IslandDTO? {
        try? JSONDecoder().decode(PushValidator.IslandDTO.self, from: Data(json.utf8))
    }

    // MARK: - DTO 容错解码

    func testIslandDTODecodesAllFields() throws {
        let dto = try XCTUnwrap(decodeIsland(#"{"text":"构建中 42%","progress":0.42,"icon":"hammer.fill"}"#))
        XCTAssertEqual(dto.text, "构建中 42%")
        XCTAssertEqual(dto.progress, 0.42)
        XCTAssertEqual(dto.icon, "hammer.fill")
    }

    /// 单字段类型错丢弃该字段，不让整个 island（乃至整条推送）解码失败。
    func testIslandDTOWronglyTypedFieldDropsOnlyThatField() throws {
        let dto = try XCTUnwrap(decodeIsland(#"{"text":42,"progress":"high","icon":"ok.fill"}"#))
        XCTAssertNil(dto.text)
        XCTAssertNil(dto.progress)
        XCTAssertEqual(dto.icon, "ok.fill", "类型正确的相邻字段必须存活")
    }

    func testIslandDTOMissingFieldsDecodeAsNil() throws {
        let dto = try XCTUnwrap(decodeIsland("{}"))
        XCTAssertNil(dto.text)
        XCTAssertNil(dto.progress)
        XCTAssertNil(dto.icon)
    }

    // MARK: - 归一化闸

    func testNormalizedIslandTrimsAndCapsText() {
        let long = "  " + String(repeating: "字", count: 100) + "  "
        let island = PushValidator.normalizedIsland(PushValidator.IslandDTO(text: long))
        XCTAssertEqual(island?.text?.count, PushValidator.maxIslandTextLength)
    }

    func testNormalizedIslandClampsProgress() {
        XCTAssertEqual(PushValidator.normalizedIsland(PushValidator.IslandDTO(progress: 1.7))?.progress, 1)
        XCTAssertEqual(PushValidator.normalizedIsland(PushValidator.IslandDTO(progress: -0.5))?.progress, 0)
        XCTAssertEqual(PushValidator.normalizedIsland(PushValidator.IslandDTO(progress: 0.42))?.progress, 0.42)
    }

    /// NaN/Inf 不是大数，是垃圾：进模型后会毒化 history 落盘的 JSONEncoder
    /// （clampedTimeout 判例），一律当作未提供。
    func testNormalizedIslandDropsNonFiniteProgress() {
        for raw in [Double.nan, .infinity, -.infinity] {
            let island = PushValidator.normalizedIsland(PushValidator.IslandDTO(text: "构建中", progress: raw))
            XCTAssertNil(island?.progress, "\(raw) 必须被丢弃")
            XCTAssertEqual(island?.text, "构建中", "相邻字段不受连坐")
        }
    }

    /// 整体缺失或全空 → nil：渲染层对 nil 保持接入前的行为，一个像素不变。
    func testNormalizedIslandAllEmptyIsNil() {
        XCTAssertNil(PushValidator.normalizedIsland(nil))
        XCTAssertNil(PushValidator.normalizedIsland(PushValidator.IslandDTO()))
        XCTAssertNil(PushValidator.normalizedIsland(PushValidator.IslandDTO(text: "   ", icon: " ")))
        XCTAssertNil(PushValidator.normalizedIsland(PushValidator.IslandDTO(progress: .nan)),
                     "唯一的字段被丢弃后，island 整体为 nil")
    }

    func testNormalizedIslandKeepsSingleField() {
        let progressOnly = PushValidator.normalizedIsland(PushValidator.IslandDTO(progress: 0.5))
        XCTAssertEqual(progressOnly, IslandContent(progress: 0.5))
        let iconOnly = PushValidator.normalizedIsland(PushValidator.IslandDTO(icon: "hammer.fill"))
        XCTAssertEqual(iconOnly, IslandContent(icon: "hammer.fill"))
    }

    // MARK: - HTTP / WS 两门端到端 + 跨门一致性

    /// 同一份 island 载荷，HTTP 与 WS 两个 JSON 门的产物必须一致——
    /// testPushBlocksAcrossHTTPAndWSIngress 的 island 版：归一化共用
    /// `normalizedIsland`，防止某个门长出自己的规则。
    func testPushIslandAcrossHTTPAndWSIngress() async throws {
        let island: [String: Any] = ["text": "  构建中 42%  ", "progress": 1.7, "icon": "hammer.fill"]
        let http = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: try JSONSerialization.data(withJSONObject: ["title": "部署", "island": island])))
        XCTAssertEqual(http.status, 200)

        let ws = await router.handleWSCommand(try JSONSerialization.data(
            withJSONObject: ["op": "push", "title": "部署", "island": island]))
        let frame = try JSONSerialization.jsonObject(with: ws) as! [String: Any]
        XCTAssertEqual(frame["ok"] as? Bool, true)

        // 两门产物一致，且都已过归一化闸（trim + clamp）。
        let islands = manager.history.map(\.island)
        XCTAssertEqual(islands.count, 2)
        XCTAssertEqual(islands[0], islands[1])
        XCTAssertEqual(islands[0], IslandContent(text: "构建中 42%", progress: 1, icon: "hammer.fill"))
    }

    /// 类型错的 island 字段不得让整条推送 400（truncate, never reject）。
    func testPushWithBrokenIslandFieldsStillSucceeds() async throws {
        let body = #"{"title":"部署","island":{"text":"构建中","progress":"high"}}"#
        let http = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: Data(body.utf8)))
        XCTAssertEqual(http.status, 200)
        XCTAssertEqual(manager.history.last?.island, IslandContent(text: "构建中"))
    }

    /// 不带 island 的推送：模型字段为 nil，渲染层走接入前的行为。
    func testPushWithoutIslandHasNilIsland() async throws {
        let http = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: try JSONSerialization.data(withJSONObject: ["title": "部署"])))
        XCTAssertEqual(http.status, 200)
        XCTAssertNil(manager.history.last?.island)
    }

    /// URL Scheme 不载结构化字段（blocks 同判例）：URL 入口的产物 island 恒为 nil。
    func testURLSchemePushNeverCarriesIsland() throws {
        let n = try URLNotificationParser.parsePushDetailed(
            URL(string: "notch-notify://push?title=Hi")!).get()
        XCTAssertNil(n.island)
    }

    // MARK: - compactStatus（唯一 island 感知访问器）

    func testCompactStatusPrefersIslandText() {
        manager.push(NotchNotification(
            title: "部署", bodyMarkdown: "", urgency: .normal, timeout: nil,
            island: IslandContent(text: "构建中 42%")))
        XCTAssertEqual(manager.compactStatus, "构建中 42%")
    }

    func testCompactStatusWithoutIslandIsUnchanged() {
        manager.push(NotchNotification(title: "t", bodyMarkdown: "", urgency: .normal, timeout: nil))
        XCTAssertEqual(manager.compactStatus, "新消息")
        manager.push(NotchNotification(title: "t2", bodyMarkdown: "", urgency: .critical, timeout: nil))
        XCTAssertEqual(manager.compactStatus, "需要注意")
    }
}
