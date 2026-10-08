using System;
using System.Collections.Generic;
using System.Windows;
using DeskIsle.Models;

namespace DeskIsle.Services
{
    public static class SnappingManager
    {
        public const double SnapThreshold = 16.0;

        /// <summary>
        /// 磁吸计算：针对屏幕边界与其它分区边界进行磁吸吸附。
        /// ⚠️ 边距与间距必须复用 LayoutEngine.Margin / LayoutEngine.Gap（均为 16）：
        /// 历史上边缘磁吸硬编码 8px、顶边 60px，与排版基准 16px / topMargin 76px 不一致，
        /// 导致「手动拖过的分区间隔比排版基准小、换行后与屏幕左侧间隔偏大」。
        /// </summary>
        public static (double X, double Y) Snap(
            string activeId,
            double proposedX,
            double proposedY,
            double width,
            double height,
            List<PartitionModel> allPartitions,
            Rect workArea,
            double topMargin = 76.0)
        {
            double snappedX = proposedX;
            double snappedY = proposedY;

            // 1. 屏幕工作区边缘吸附（统一使用 LayoutEngine.Margin / topMargin）
            // 左边缘
            if (Math.Abs(proposedX - (workArea.Left + LayoutEngine.Margin)) < SnapThreshold)
                snappedX = workArea.Left + LayoutEngine.Margin;
            // 右边缘
            else if (Math.Abs(proposedX + width - (workArea.Right - LayoutEngine.Margin)) < SnapThreshold)
                snappedX = workArea.Right - width - LayoutEngine.Margin;

            // 顶边缘（顶层分区与导航栏底部保持 topMargin）
            if (Math.Abs(proposedY - (workArea.Top + topMargin)) < SnapThreshold)
                snappedY = workArea.Top + topMargin;
            // 底边缘
            else if (Math.Abs(proposedY + height - (workArea.Bottom - LayoutEngine.Margin)) < SnapThreshold)
                snappedY = workArea.Bottom - height - LayoutEngine.Margin;

            // 2. 邻近其它分区边界吸附
            foreach (var other in allPartitions)
            {
                if (other.Id == activeId) continue;

                double otherLeft = other.X;
                double otherRight = other.X + other.Width;
                double otherTop = other.Y;
                double otherBottom = other.Y + (other.IsCollapsed ? 44.0 : other.Height);

                // 水平间距对齐 (Left to Right / Right to Left，含标准间距与无缝贴合)
                if (Math.Abs(proposedX - (otherRight + LayoutEngine.Gap)) < SnapThreshold)
                    snappedX = otherRight + LayoutEngine.Gap;
                else if (Math.Abs(proposedX - otherRight) < SnapThreshold)
                    snappedX = otherRight;
                else if (Math.Abs(proposedX + width + LayoutEngine.Gap - otherLeft) < SnapThreshold)
                    snappedX = otherLeft - width - LayoutEngine.Gap;
                else if (Math.Abs(proposedX + width - otherLeft) < SnapThreshold)
                    snappedX = otherLeft - width;
                else if (Math.Abs(proposedX - otherLeft) < SnapThreshold) // 左对齐
                    snappedX = otherLeft;
                else if (Math.Abs(proposedX + width - otherRight) < SnapThreshold) // 右对齐
                    snappedX = otherRight - width;

                // 垂直间距对齐 (Top to Bottom / Bottom to Top，含标准间距与无缝贴合)
                if (Math.Abs(proposedY - (otherBottom + LayoutEngine.Gap)) < SnapThreshold)
                    snappedY = otherBottom + LayoutEngine.Gap;
                else if (Math.Abs(proposedY - otherBottom) < SnapThreshold)
                    snappedY = otherBottom;
                else if (Math.Abs(proposedY + height + LayoutEngine.Gap - otherTop) < SnapThreshold)
                    snappedY = otherTop - height - LayoutEngine.Gap;
                else if (Math.Abs(proposedY + height - otherTop) < SnapThreshold)
                    snappedY = otherTop - height;
                else if (Math.Abs(proposedY - otherTop) < SnapThreshold) // 顶对齐
                    snappedY = otherTop;
                else if (Math.Abs(proposedY + height - otherBottom) < SnapThreshold) // 底对齐
                    snappedY = otherBottom - height;
            }

            return (snappedX, snappedY);
        }
    }
}
