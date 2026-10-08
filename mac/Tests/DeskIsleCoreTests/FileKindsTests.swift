import XCTest
@testable import DeskIsleCore

/// 「包（package）不是目录」这条判定的回归护栏。
///
/// 这条规则一旦被改回「直接看 isDirectory」，表现是**应用在映射文件夹里变成蓝色文件夹、
/// 双击钻进 `Foo.app/Contents/MacOS`**；而它不会让任何测试变红、也不会崩 ——
/// 只会让用户某天发现「应用打不开了」。所以必须有断言钉住。
final class FileKindsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deskisle-filekinds-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 造一个**真的** app bundle（带 Info.plist），避免测试依赖「空目录也算包」这种边角行为。
    @discardableResult
    private func makeFakeApp(_ name: String = "Demo.app") throws -> URL {
        let app = root.appendingPathComponent(name)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data().write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    // MARK: - 基本分类

    func testRegularDirectoryIsADirectory() throws {
        let dir = root.appendingPathComponent("素材")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = FileKinds.meta(ofPath: dir.path)
        XCTAssertTrue(meta.isPhysicalDirectory)
        XCTAssertFalse(meta.isPackage)
        XCTAssertTrue(meta.isDirectory)
    }

    func testPlainFileIsNotADirectory() throws {
        let file = root.appendingPathComponent("a.pdf")
        try Data().write(to: file)
        let meta = FileKinds.meta(ofPath: file.path)
        XCTAssertFalse(meta.isPhysicalDirectory)
        XCTAssertFalse(meta.isPackage)
        XCTAssertFalse(meta.isDirectory)
    }

    // MARK: - 核心：包

    func testAppBundleIsAPackageNotADirectory() throws {
        let app = try makeFakeApp()
        let meta = FileKinds.meta(ofPath: app.path)
        XCTAssertTrue(meta.isPhysicalDirectory, "`.app` 在 stat 上确实是目录 —— 这正是坑的由来")
        XCTAssertTrue(meta.isPackage, "`.app` 必须是包")
        XCTAssertFalse(meta.isDirectory, "★ 应用必须被当作**文件**：否则会显示成文件夹、双击钻进去")
    }

    func testPackageContentsAreNormalDirectories() throws {
        // 反向约束：只有包自身特殊，包**内部**依旧按普通目录处理，
        // 否则「显示包内容」进去后会遇到一屏无法进入的目录。
        let app = try makeFakeApp()
        let contents = app.appendingPathComponent("Contents")
        let meta = FileKinds.meta(ofPath: contents.path)
        XCTAssertTrue(meta.isPhysicalDirectory)
        XCTAssertFalse(meta.isPackage, "包的后代不是包，`Contents` 就该是个普通目录")
        XCTAssertTrue(meta.isDirectory)
    }

    func testOtherPackageKindsAreAlsoOpaque() throws {
        // `.bundle` / `.pages` 之类与 `.app` 同理，都不该被当成可展开的目录
        for name in ["Demo.bundle", "报告.pages", "Demo.framework"] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            XCTAssertFalse(FileKinds.meta(ofPath: url.path).isDirectory,
                           "\(name) 是包，应被当作文件")
        }
    }

    func testARegularFileNamedLikeAPackageIsNotAPackage() throws {
        // 名字叫 `.app` 的普通文件（不是目录）不该被误判成包 ——
        // 包的前提是「目录 + 包类型」，少了目录这一半就会把一堆普通文件当应用。
        let file = root.appendingPathComponent("not-really.app")
        try Data().write(to: file)
        let meta = FileKinds.meta(ofPath: file.path)
        XCTAssertFalse(meta.isPhysicalDirectory)
        XCTAssertFalse(meta.isPackage)
        XCTAssertFalse(meta.isDirectory)
    }

    // MARK: - 兜底与缺省

    func testPackageExtensionTableCoversApp() {
        // 资源值取不到时靠这张表兜底；至少 `.app` 必须在里面
        XCTAssertTrue(FileKinds.packageExtensions.contains("app"))
        XCTAssertTrue(FileKinds.packageExtensions.contains("bundle"))
    }

    func testMissingPathFallsBackToNotADirectory() {
        // 路径不存在时不能抛错、也不能被当成目录（视图里这条路径会直接按文件渲染）
        let meta = FileKinds.meta(ofPath: root.appendingPathComponent("查无此物").path)
        XCTAssertFalse(meta.isPhysicalDirectory)
        XCTAssertFalse(meta.isPackage)
        XCTAssertFalse(meta.isDirectory)
        XCTAssertEqual(meta.size, 0)
        XCTAssertEqual(meta.modDate, Date.distantPast)
    }

    func testSizeAndModDateArePopulatedForFiles() throws {
        let file = root.appendingPathComponent("a.txt")
        try Data(repeating: 0x41, count: 1234).write(to: file)
        let meta = FileKinds.meta(ofPath: file.path)
        XCTAssertEqual(meta.size, 1234, "旧代码用 attributesOfItem 取大小，换成 resourceValues 后口径必须一致")
        XCTAssertNotEqual(meta.modDate, Date.distantPast)
    }

    // MARK: - 双击动作（三端同源）
    //
    // ⚠️ 这三组断言（本文件 / `windows/tests/…/CoreLogicTests.cs` / `electron/scripts/verify-logic.mts`）
    // **必须一起改**：判据分散在三份代码里，只改一处会让同一目录在三端双击出不同结果。

    func testImagesGoToPreview() {
        for name in ["截图.PNG", "photo.jpg", "a.JPEG", "gif.gif", "x.webp", "x.heic", "x.tif"] {
            XCTAssertTrue(FileKinds.isImage("/tmp/\(name)"), "\(name) 应识别为图片")
            XCTAssertEqual(FileKinds.doubleClickAction(isDirectory: false, path: "/tmp/\(name)"),
                           .previewImage)
        }
    }

    func testNonImagesGoToSystemOpener() {
        // svg / ico 故意不在清单里：WPF 解不开 SVG，宁可交给系统默认程序
        // 也不要弹一个空白预览框。
        for name in ["报告.pdf", "a.docx", "logo.svg", "icon.ico", "notes.txt", "a.zip"] {
            XCTAssertFalse(FileKinds.isImage("/tmp/\(name)"), "\(name) 不该走预览")
            XCTAssertEqual(FileKinds.doubleClickAction(isDirectory: false, path: "/tmp/\(name)"),
                           .openExternally)
        }
    }

    func testDirectoriesAlwaysEnter() {
        // 哪怕目录名以图片后缀结尾（真实世界里有这种目录），也必须进入而不是预览
        XCTAssertEqual(FileKinds.doubleClickAction(isDirectory: true, path: "/tmp/相册.png"),
                       .enterDirectory)
        XCTAssertEqual(FileKinds.doubleClickAction(isDirectory: true, path: "/tmp/素材"),
                       .enterDirectory)
    }

    func testExtensionMatchIsCaseInsensitiveAndIgnoresDotfiles() {
        XCTAssertTrue(FileKinds.isImage("/tmp/A.PNG"))
        XCTAssertFalse(FileKinds.isImage("/tmp/.png"))     // 以点开头且没有名字 ⇒ 不是扩展名
        XCTAssertFalse(FileKinds.isImage("/tmp/noext"))
        XCTAssertFalse(FileKinds.isImage(""))
    }

    func testArchiveExtensionsAndRecognition() {
        for ext in ["zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "7z", "rar"] {
            XCTAssertTrue(FileKinds.archiveExtensions.contains(ext))
            XCTAssertTrue(FileKinds.isArchive("/path/to/archive.\(ext)"))
            XCTAssertTrue(FileKinds.isArchive("/path/to/ARCHIVE.\(ext.uppercased())"))
        }
        XCTAssertFalse(FileKinds.isArchive("/path/to/normal.txt"))
        XCTAssertFalse(FileKinds.isArchive("/path/to/.zip"))
        XCTAssertFalse(FileKinds.isArchive(""))
    }
}
