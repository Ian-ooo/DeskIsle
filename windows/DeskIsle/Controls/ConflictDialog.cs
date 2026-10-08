using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace DeskIsle.Controls
{
    /// <summary>
    /// 同名冲突的三种处理（与 mac / Electron 三端一致）：
    /// <see cref="KeepBoth"/>（自动加「 2」）、<see cref="Stop"/>（整体取消）、<see cref="Replace"/>（覆盖）。
    /// </summary>
    internal enum MoveConflictDecision { KeepBoth, Stop, Replace }

    /// <summary>
    /// 同名冲突三选一弹窗（保留两者 / 停止 / 替换）。
    ///
    /// <para>
    /// 用自定义 <see cref="Window"/> 而不是 <see cref="MessageBox"/>：后者的按钮只能是
    /// OK / YesNo / YesNoCancel，塞不进三个自定义中文标签。
    /// </para>
    /// 默认「保留两者」（回车）、「停止」（Esc 取消）最安全，不会因误点而覆盖数据。
    /// </summary>
    internal static class ConflictDialog
    {
        public static MoveConflictDecision Show(string[]? names)
        {
            var decision = MoveConflictDecision.Stop; // 默认取消，最安全
            var dlg = new Window
            {
                Title = "目标文件夹中已有同名文件",
                Width = 420,
                Height = 260,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                ResizeMode = ResizeMode.NoResize,
                ShowInTaskbar = false,
                Owner = Application.Current?.MainWindow
            };

            var safeNames = names ?? new string[0];
            var panel = new StackPanel { Margin = new Thickness(20) };
            var tb = new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 18),
                Text = "以下文件已存在，如何处理？\n" +
                       string.Join("\n", safeNames.Take(5).Select(n => "• " + n)) +
                       (safeNames.Length > 5 ? $"\n…等 {safeNames.Length} 个文件" : "")
            };
            panel.Children.Add(tb);

            var buttons = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right
            };
            var keep = new Button { Content = "保留两者", Width = 92, Height = 30, Margin = new Thickness(4), IsDefault = true };
            var stop = new Button { Content = "停止", Width = 92, Height = 30, Margin = new Thickness(4), IsCancel = true };
            var replace = new Button { Content = "替换", Width = 92, Height = 30, Margin = new Thickness(4) };
            keep.Click += (_, __) => { decision = MoveConflictDecision.KeepBoth; dlg.Close(); };
            stop.Click += (_, __) => { decision = MoveConflictDecision.Stop; dlg.Close(); };
            replace.Click += (_, __) => { decision = MoveConflictDecision.Replace; dlg.Close(); };
            buttons.Children.Add(keep);
            buttons.Children.Add(stop);
            buttons.Children.Add(replace);
            panel.Children.Add(buttons);

            dlg.Content = panel;
            dlg.ShowDialog();
            return decision;
        }
    }
}
