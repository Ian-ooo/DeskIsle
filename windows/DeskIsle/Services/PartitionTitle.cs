using System.Text.RegularExpressions;

namespace DeskIsle.Services
{
    /// <summary>
    /// 分区标题的「图标 + 文字」拆分与拼装。
    ///
    /// 抽出来是因为它被两处使用：分区标题栏渲染、以及分区设置面板的改名。
    /// 之前这段正则在标题栏里内联，设置面板再抄一份 —— 两处一旦漂移，
    /// 就会出现「标题栏显示 📁、设置里改完变成 📁📁」这种低级但难查的问题。
    ///
    /// 关键点：**首部 emoji 是标题的一部分**（标题以 emoji 打头是三端的既定格式），
    /// 所以拆分必须能识别代理对（surrogate pair）与 So/Cs 类字符，
    /// 否则「📁 映射文件夹」会被切出一个乱码半字符。
    /// </summary>
    public static class PartitionTitle
    {
        private static readonly Regex LeadingIcon = new(
            @"^([\uD800-\uDBFF][\uDC00-\uDFFF]|\p{So}|\p{Cs}|📁|✅|📝|📥)\s*",
            RegexOptions.Compiled);

        /// <summary>分区类型对应的默认图标（标题里没有 emoji 时使用）。</summary>
        public static string DefaultIconOf(string? type) => type switch
        {
            "portal" => "📁",
            "todo" => "✅",
            "notes" => "📝",
                _ => "📦"
        };

        /// <summary>拆分标题：返回（图标, 纯文本）。文本为空时返回「未命名分区」。</summary>
        public static (string Icon, string Text) Split(string? raw, string? type)
        {
            string source = raw ?? string.Empty;
            var match = LeadingIcon.Match(source);
            if (match.Success)
            {
                string icon = match.Groups[1].Value;
                string text = source.Substring(match.Length);
                return (icon, string.IsNullOrEmpty(text) ? "未命名分区" : text);
            }
            return (DefaultIconOf(type), string.IsNullOrEmpty(source) ? "未命名分区" : source);
        }

        /// <summary>拼回标题（存进配置的形态）。</summary>
        public static string Compose(string? icon, string? text)
        {
            string i = string.IsNullOrWhiteSpace(icon) ? "📦" : icon!.Trim();
            string t = string.IsNullOrWhiteSpace(text) ? "未命名分区" : text!.Trim();
            return $"{i} {t}";
        }
    }
}
