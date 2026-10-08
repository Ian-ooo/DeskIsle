namespace DeskIsle.Services
{
    /// <summary>
    /// 「活跃分区变了」时，某个分区的选区该不该失效 ——
    /// 与 mac <c>Sources/DeskIsleCore/FileSelection.swift</c> 的
    /// <c>FileSelectionScope</c> <b>逐条同源</b>。
    /// </summary>
    ///
    /// <remarks>
    /// <para>
    /// 为什么需要它：选区是每个分区<b>各自</b>存的一份状态，天然不会互相看见。
    /// 于是用户在一个分区里选中几个文件、转头去操作另一个分区（或点到桌面 / 别的应用）时，
    /// 原来那个分区的高亮<b>还亮着</b> —— 等他再回来随手一拖，
    /// 拖走的就是那几个早就忘了的选中项，而他自己以为只拖了鼠标底下那一个。
    /// （2026-10-01 事故：想拖一张 png，结果连另一个分区的图一起被搬去了桌面。）
    /// </para>
    ///
    /// <para>
    /// ⚠️ 判据就是「活跃分区是不是自己」，两种失效来源：
    /// 1. <c>activeID == null</c> —— 点到<b>分区之外</b>（桌面 / 其它应用 / 应用退活）：
    ///    <b>所有</b>分区的选区失效；
    /// 2. <c>activeID != ownID</c> —— 操作了<b>另一个</b>分区：只有别人失效。
    /// </para>
    ///
    /// <para>
    /// 反过来 <c>activeID == ownID</c> 时必须保留 —— 点自己的空白区、滚动条、工具栏
    /// 都会重发一次「我活跃」，若这里也清，选中就没法用了。
    /// </para>
    ///
    /// <para>
    /// Windows 上目前只会走到第 1 种（宿主窗口 <c>Deactivated</c>）：
    /// 分区各是一个独立 Window，切到别的分区时旧窗口必然先 <c>Deactivated</c>。
    /// 第 2 种的分支照写，免得哪天改成单窗口多分区时漏掉。
    /// </para>
    /// </remarks>
    public static class FileSelectionScope
    {
        /// <summary>
        /// 本分区的选区是否该失效。
        /// </summary>
        /// <param name="ownID">本分区 id。</param>
        /// <param name="activeID">当前活跃分区 id；<c>null</c> = 活跃的不在任何一个分区里。</param>
        public static bool ShouldClear(string ownID, string? activeID)
        {
            if (activeID == null) return true;
            return activeID != ownID;
        }
    }
}
