// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeskIsle",
    platforms: [.macOS(.v13)],
    targets: [
        // 纯计算核心：排版基准（Layout）、尺寸口径（PartitionMetrics）、坐标解算（LayoutEngine）。
        //
        // 单独拆成 target 的唯一目的是**可以被测试**：executable target 无法被 testTarget 导入，
        // 而这三块恰是历史上出过回归的地方（排版基准不一致、子文件夹自适应高度、
        // 跨屏吸附坐标系不统一），必须有断言兜住。
        .target(
            name: "DeskIsleLayout",
            path: "Sources/DeskIsleLayout"
        ),
        // 另一块纯逻辑：文件相关判据（拖出发起、条目选中、双击动作、键盘、类型判定、搜索匹配）。
        // 同样因为「测得到」而独立 —— 这类逻辑写错时往往不报错，
        // 只表现为「拖 A 搬走了 B」这种不出事则已、出事很难查的现象。
        .target(
            name: "DeskIsleCore",
            path: "Sources/DeskIsleCore"
        ),
        .executableTarget(
            name: "DeskIsle",
            dependencies: ["DeskIsleLayout", "DeskIsleCore"],
            path: "Sources/DeskIsle"
        ),
        // 跨端对拍的 mac 侧输出工具（Electron 端移除后接替 `scripts/crosscheck/js-reference.mts`）。
        //
        // 它直接调用真实 `LayoutEngine`，把 15 个场景的坐标打成 JSON，交给
        // `scripts/crosscheck/compare.py` 与 Windows 侧的直译结果比对。
        // 于是对拍第一次真正比到了**功能基线**（旧方案比的是 Electron，从未对上基线）。
        .executableTarget(
            name: "CrosscheckDump",
            dependencies: ["DeskIsleLayout"],
            path: "Sources/CrosscheckDump"
        ),
        .testTarget(
            name: "DeskIsleLayoutTests",
            dependencies: ["DeskIsleLayout"],
            path: "Tests/DeskIsleLayoutTests"
        ),
        .testTarget(
            name: "DeskIsleCoreTests",
            dependencies: ["DeskIsleCore"],
            path: "Tests/DeskIsleCoreTests"
        )
    ]
)
