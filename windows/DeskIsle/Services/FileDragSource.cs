using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using Microsoft.VisualBasic.FileIO;

namespace DeskIsle.Services
{
    /// <summary>
    /// 把分区内的文件 / 文件夹**拖出去**（拖到资源管理器、桌面、其它应用）。
    ///
    /// 对齐 mac 基线：mac 的 `PartitionView.fileDragProvider` 用 `NSItemProvider(contentsOf:)`
    /// 携带**真实文件 URL**（不是文本），目录同样支持 —— 所以这里也用标准的
    /// <c>DataFormats.FileDrop</c>，而不是塞纯文本路径。
    ///
    /// <para>
    /// ⚠️ 与「拖入」是两件事，不要混淆：
    /// 拖入（便签 / 待办接收外部文件）早已实现，见各 View 的 <c>Drop</c> 处理；
    /// 拖出此前**完全没有**，是相对 mac 基线缺失的一项。
    /// </para>
    ///
    /// <para>
    /// 用法（XAML）：在文件条目的容器上加
    /// <c>PreviewMouseMove="FileItem_PreviewMouseMove"</c>；
    /// 后置代码里调用 <see cref="TryBegin(FrameworkElement, string)"/>。
    /// 用 <c>PreviewMouseMove</c> 而不是 <c>MouseMove</c>，是因为条目上还有
    /// <c>MouseLeftButtonDown</c>（双击打开），冒泡到上层可能被吃掉。
    /// </para>
    /// </summary>
    public static class FileDragSource
    {
        /// <summary>
        /// 本次拖放是否已被<b>本应用自己的落点</b>接手。
        ///
        /// <para>
        /// ⚠️ 必须区分：应用内部拖放（分区↔分区、拖到文件夹条目上）由
        /// <see cref="DeskIsle.Controls.FolderDrop.OnDrop"/> 自己把文件搬走，
        /// 并且它同样会给系统返回 <c>Move</c>。若这里不看这个标志，
        /// 拖放结束后会再执行一次「删原件」—— 而原件此时已经被搬到了目标分区，
        /// 于是用户看到的就是「拖进去了又立刻没了」。
        /// </para>
        /// </summary>
        public static bool InAppDropHandled { get; set; }

        // ── 发起判据的状态（与 mac `FileDragSourceView` 同一口径） ──────────
        //
        // ⚠️ 为什么 Windows 也要这一套：`PreviewMouseMove` 是**每次鼠标移动**都触发，
        // 原本一移动就 `DoDragDrop`，既没有 4pt 阈值（手抖就发起），
        // 也没有「一次按下只发起一次」的锁 —— 拖完返回后鼠标继续移动会**再发起一次**，
        // 用户看到的就是「拖了一个，结果连着发起第二次拖拽」。
        // 判据本身在 `FileDragLaunch`（两端同源、有断言覆盖），这里只存状态。

        private static FrameworkElement? _downElement;
        private static Point _downPoint;
        private static bool _downValid;
        private static bool _began;
        private static bool _sessionActive;

        /// <summary>
        /// 记录一次左键按下（条目的 <c>PreviewMouseDown</c> 里调用）。
        /// 没有它就没有「位移阈值」和「按下点是否在<b>本</b>条目上」这两条判据。
        /// </summary>
        public static void NoteMouseDown(FrameworkElement? element, Point positionInElement)
        {
            _downElement = element;
            _downPoint = positionInElement;
            _downValid = element != null;
            _began = false;
            // 兜底解锁：万一上一次会话没正常收尾，这一次按下自动解掉，不会永远拖不动。
            _sessionActive = false;
        }

        /// <summary>
        /// 窗口标识 —— 只为让「事件窗口 == 本行窗口」这条判据两端同形。
        /// Windows 用路由事件，这条恒真；留着是为了和 mac 共用同一个纯函数。
        /// </summary>
        private static int WindowIdOf(FrameworkElement? e)
            => e == null ? 0 : (Window.GetWindow(e)?.GetHashCode() ?? 0);

        /// <summary>本次移动是否满足发起拖出的全部条件（判据见 <see cref="FileDragLaunch"/>）。</summary>
        public static bool ShouldBegin(FrameworkElement source, Point currentInSource)
        {
            int id = WindowIdOf(source);
            var input = new DragLaunchInput
            {
                EventWindowID = id,
                OwnWindowID = id,
                DownWindowID = id,
                // ⚠️ 必须按下的就是<b>这个</b>条目：按住 A 横向划到 B，B 也会收到
                // PreviewMouseMove，不放这条就会把 B 拖出去。
                DownInsideRow = _downValid && ReferenceEquals(_downElement, source),
                AlreadyBegan = _began,
                AnotherSessionActive = _sessionActive,
                Dx = currentInSource.X - _downPoint.X,
                Dy = currentInSource.Y - _downPoint.Y,
            };
            return FileDragLaunch.ShouldBegin(input);
        }

        /// <summary>
        /// 在按住左键拖动时发起一次文件拖放。
        /// 任何不满足条件的情况都**静默返回** —— 拖放失败不该打断正常操作。
        /// </summary>
        /// <param name="source">发起拖动的视觉元素（DataContext 已绑定条目）。</param>
        /// <param name="path">要拖出的文件 / 文件夹的完整路径。</param>
        /// <param name="current">当前鼠标位置（相对 <paramref name="source"/>）。</param>
        /// <param name="onChanged">原件被移走后刷新列表（传入方的 ReloadItems）。</param>
        public static void TryBegin(FrameworkElement source, string? path, Point current,
                                    Action? onChanged = null)
        {
            if (!ShouldBegin(source, current)) return;

            _began = true;
            _sessionActive = true;
            try
            {
                // 记录本次拖放有没有落到自己身上：FolderDrop.OnDrop 会在真正搬文件时置位
                InAppDropHandled = false;
                var effect = Begin(source, path);
                // ⚠️ 只有「对方明确完成了移动」且「不是本应用自己接的」才删原件。
                // 资源管理器在同卷时会回 Move（它已复制完成、等我们删原件），跨卷回 Copy —— 正是访达的口径。
                if (!InAppDropHandled && effect == DragDropEffects.Move)
                {
                    RemoveOriginals(new[] { path! }, onChanged);
                }
            }
            finally
            {
                _sessionActive = false;
                // 本次按下已经用掉了：不放这行，DoDragDrop 返回后鼠标再动就会二次发起。
                _downValid = false;
            }
        }

        /// <summary>
        /// 拖出成功后，<b>等多久</b>才轮到我们动原件（毫秒）。
        ///
        /// <para>
        /// ⚠️⚠️ 与 mac 的 <c>FileDrag.settleDelay</c> 同一口径，别再改回 0。
        /// 资源管理器接收拖放后是<b>异步</b>拷贝的：<c>DoDragDrop</c> 返回时，
        /// 它的拷贝任务很可能才刚开始读源文件。此时删原件会让拷贝<b>中途断流</b>，
        /// 于是资源管理器报错，而原件已被我们删掉、目标又没拷成 ——
        /// 用户看到的就是「两边都没有」。拖文件夹时（递归拷贝）尤其明显。
        /// </para>
        ///
        /// <para>
        /// 窗口只是估算，所以另一半保障是：<b>一律进回收站、绝不硬删</b>
        /// —— 万一窗口不够，用户还能从回收站把原件捞回来。
        /// </para>
        /// </summary>
        public static int SettleDelayMs(bool containsDirectory) => containsDirectory ? 12000 : 3000;

        /// <summary>
        /// 真正发起拖放并返回<b>系统最终执行的操作</b>（Copy / Move / None）。
        /// 任何异常都静默吞掉 —— 拖放被系统拒绝时不该打断用户。
        /// </summary>
        private static DragDropEffects Begin(FrameworkElement source, string? path)
        {
            // 只有「按住左键移动」才算拖动；否则鼠标划过条目就会触发拖放。
            if (Mouse.LeftButton != MouseButtonState.Pressed) return DragDropEffects.None;
            if (source == null || string.IsNullOrWhiteSpace(path)) return DragDropEffects.None;

            // 路径必须真实存在：已被外部删掉的条目拖出去会变成空操作，
            // 不如直接不发起，免得用户看到「拖了但没反应」。
            bool exists = false;
            try
            {
                exists = File.Exists(path) || Directory.Exists(path);
            }
            catch
            {
                // 路径含非法字符时 Exists 会抛异常 —— 当作不存在
                return DragDropEffects.None;
            }
            if (!exists) return DragDropEffects.None;

            try
            {
                // ⚠️ FileDrop 必须是 string[] —— 传单个 string 资源管理器不认。
                var data = new DataObject(DataFormats.FileDrop, new[] { path });
                // Copy | Move：由对方（资源管理器 / 桌面 / 其它应用）按同卷 / 跨卷决定最终操作，
                // 并把结果**同步返回**给我们 —— 这正是 OLE 拖放里「源负责删原件」的契约。
                return DragDrop.DoDragDrop(source, data, DragDropEffects.Copy | DragDropEffects.Move);
            }
            catch
            {
                // 拖放被系统拒绝（例如权限）时静默放弃，不弹错、不打断。
                return DragDropEffects.None;
            }
        }

        /// <summary>
        /// 拖出已被对方完成为「移动」后处理掉原件 —— 与把文件拖到同卷别处一致。
        ///
        /// <para>
        /// ⚠️ <b>不立刻删</b>：先等 <see cref="SettleDelayMs"/>，让对方的异步拷贝落定。
        /// 走到这里时对方只是<b>接受了</b>移动（回 <c>Move</c>），
        /// 不等于它已经把字节拷完 —— 早删会掐断它的拷贝，
        /// 而原件已被我们删掉，用户看到的就是「两边都没有」。
        /// </para>
        /// </summary>
        private static void RemoveOriginals(IEnumerable<string> paths, Action? onChanged)
        {
            var pending = paths
                .Where(p => !string.IsNullOrWhiteSpace(p) && (File.Exists(p) || Directory.Exists(p)))
                .ToList();
            if (pending.Count == 0) return;

            int delayMs = SettleDelayMs(pending.Any(Directory.Exists));

            _ = Task.Delay(delayMs).ContinueWith(_ =>
            {
                int removed = 0;
                foreach (var path in pending)
                {
                    try
                    {
                        // 对方可能已自己把原件搬走（同卷 rename）—— 那就什么都不用做
                        if (!File.Exists(path) && !Directory.Exists(path)) continue;

                        // ⚠️ 一律进回收站，绝不硬删：等待窗口只是估算，
                        // 真被掐断时用户还能从回收站把原件捞回来。
                        if (Directory.Exists(path))
                            FileSystem.DeleteDirectory(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
                        else
                            FileSystem.DeleteFile(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
                        removed++;
                    }
                    catch
                    {
                        // 删不掉（被占用 / 权限）就留着 —— 宁可重复一份，也不能让用户以为文件丢了。
                    }
                }

                if (removed > 0 && onChanged != null)
                    Application.Current?.Dispatcher.BeginInvoke(onChanged);
            }, TaskScheduler.Default);
        }
    }
}
