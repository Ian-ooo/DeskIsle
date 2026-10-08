import XCTest
import CoreGraphics
@testable import DeskIsleLayout

/// 「拖拽尺寸提示」胶囊的落位。
///
/// ⚠️ 这些用例存在的理由：桌面被 IDE / 聊天窗口铺满时，真机上没法用合成鼠标去拖分区
/// （目标点顶层是别人的窗口，合成点击会打到那里），于是「贴哪个角」这种一眼可见
/// 却最容易写错的事，只能靠纯函数 + 单测钉住。contentView 是**左下原点**，
/// 右下角写错成左上角是这里的头号错误。
final class SizeHUDTests: XCTestCase {

    private let labelSize = (w: CGFloat(62), h: CGFloat(13))   // "1920 × 1080" 的实测尺寸量级

    /// 常规分区（316×428）：贴**右下角**，两边各留 10pt。
    func testSitsInBottomRightCornerWithMargin() {
        let f = SizeHUD.frame(contentWidth: 316, contentHeight: 428,
                              labelWidth: labelSize.w, labelHeight: labelSize.h)
        let expectedW = labelSize.w + SizeHUD.padX * 2
        let expectedH = labelSize.h + SizeHUD.padY * 2
        XCTAssertEqual(f.width, expectedW, accuracy: 0.001)
        XCTAssertEqual(f.height, expectedH, accuracy: 0.001)
        // 右：右边到容器右边 = margin
        XCTAssertEqual(316 - (f.maxX), SizeHUD.margin, accuracy: 0.001)
        // 下：**左下原点**，所以下边距就是 minY
        XCTAssertEqual(f.minY, SizeHUD.margin, accuracy: 0.001)
    }

    /// 跟着分区尺寸走：换一个分区尺寸，胶囊仍然贴右下角（不是写死坐标）。
    func testFollowsPartitionSize() {
        for (cw, ch) in [(280, 200), (500, 700), (120, 64)] {
            let f = SizeHUD.frame(contentWidth: CGFloat(cw), contentHeight: CGFloat(ch),
                                  labelWidth: labelSize.w, labelHeight: labelSize.h)
            XCTAssertEqual(CGFloat(cw) - f.maxX, SizeHUD.margin, accuracy: 0.001, "宽 \(cw)")
            XCTAssertEqual(f.minY, SizeHUD.margin, accuracy: 0.001, "高 \(ch)")
        }
    }

    /// 不能再小还要 **不越界**：内容比胶囊还小时（折叠态 44pt 高），不能被裁掉或挤出边界。
    func testNeverOverflowsTinyContent() {
        let f = SizeHUD.frame(contentWidth: 40, contentHeight: 44,
                              labelWidth: labelSize.w, labelHeight: labelSize.h)
        XCTAssertGreaterThanOrEqual(f.minX, 0)
        XCTAssertGreaterThanOrEqual(f.minY, 0)
        XCTAssertLessThanOrEqual(f.maxX, 40)
        XCTAssertLessThanOrEqual(f.maxY, 44)
    }

    /// 文字 label 在胶囊内的位置：左右留 padX、上下留 padY。
    func testLabelSitsInside() {
        let l = SizeHUD.labelFrame(labelWidth: labelSize.w, labelHeight: labelSize.h)
        XCTAssertEqual(l.minX, SizeHUD.padX, accuracy: 0.001)
        XCTAssertEqual(l.minY, SizeHUD.padY, accuracy: 0.001)
        XCTAssertEqual(l.size.width, labelSize.w, accuracy: 0.001)
        XCTAssertEqual(l.size.height, labelSize.h, accuracy: 0.001)
    }
}
