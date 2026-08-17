import HubIPC
import HubProjects
import XCTest
@testable import HubUI

/// `HubIPC.SensitivePaths` 里的路径是**抄**过去的常量。
///
/// 抄的理由是 `HubIPC` 刻意不依赖 `HubProjects`（`hubctl` 每次工具调用都要跑一遍，
/// 必须小而快）。抄的代价是会漂，而漂了的症状是**静默的**：
/// 密钥文件的路径改了名，那道「读密钥要拦一下」的闸就再也命不中，
/// 而界面上没有任何变化。
///
/// 这个测试目录同时看得见两个模块，所以把两边的真实路径拿来对一遍。
@MainActor
final class SensitivePathsAgreementTests: XCTestCase {

    /// 物化目录改了名，`SensitivePaths` 要跟着改。
    func testMaterializationRootIsCovered() {
        let real = EnvMaterializer.byProjectDirectory(root: EnvMaterializer.defaultRoot)
            .appendingPathComponent("hj-admin-9f3a1c8d.env").path
        XCTAssertTrue(
            SensitivePaths.matches(real),
            "SensitivePaths 认不出物化出来的密钥文件：\(real)"
        )
    }

    /// 两个库的密文本体改了名，同上。
    func testVaultFilesAreCovered() {
        for url in [SharedSecretStore.defaultURL, CredentialStore.defaultURL] {
            XCTAssertTrue(
                SensitivePaths.matches(url.path),
                "SensitivePaths 认不出密钥库文件：\(url.path)"
            )
        }
    }

    /// 反过来也要成立：判宽了会让普通文件开始弹审批。
    func testOrdinaryHubFilesAreNotCovered() {
        for url in [
            ClosedSessionStore.defaultURL,
            VerifierSettings.defaultURL,
            AcceptanceStore.defaultDirectory.appendingPathComponent("x.json"),
        ] {
            XCTAssertFalse(
                SensitivePaths.matches(url.path),
                "普通数据文件被当成了密钥：\(url.path)"
            )
        }
    }
}
