using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DeskIsle.Models;
using DeskIsle.Services;

namespace DeskIsle.Views
{
    /// <summary>
    /// 单个分区的设置面板（对齐 mac 端「分区标题栏 ⚙ → 分区设置」）。
    ///
    /// 引入它的原因很直接：Windows 版此前**没有**分区级设置入口 ——
    /// 尺寸只能靠在窗口边缘拖动、或在全局设置里改「默认高度」，
    /// 而「把某一个分区精确设成 360×220」这件事在三端里只有 Windows 做不到。
    ///
    /// 用纯代码构建、不走 XAML：面板元素全部可枚举，没有 x:Name 与代码后置的耦合，
    /// 新增一个文件也不会牵出 InitializeComponent / 分部类的一堆约定。
    /// </summary>
    public sealed class PartitionSettingsDialog : Window
    {
        private const double MinPartitionWidth = 160.0;
        private const double MinPartitionHeight = 140.0;
        private const double SizeStep = 20.0;
        private const int MaxTitleChars = 10;

        private readonly PartitionModel _model;
        private readonly Config _config;
        private readonly Action _onApplied;

        private readonly TextBox _titleBox;
        private readonly TextBox _widthBox;
        private readonly TextBox _heightBox;
        private readonly CheckBox _lockedCheck;
        private readonly CheckBox _pinCheck;
        private readonly CheckBox _collapseCheck;
        private readonly Button _autoFitBtn;
        private readonly TextBlock _sizeHint;
        private readonly string _icon;


        // 默认视图（仅「展示文件列表」的三种分区；与 mac 的 usesViewMode 同口径）
        private ComboBox? _viewModeBox;

        // ── 外观（分区级样式，覆盖全局） ──────────────────────────
        // ⚠️ 与 mac `PartitionSettingsView` / Electron `PartitionSettingsModal` **同一个六键契约**
        //    （bgColor / bgOpacity / borderRadius / blurAmount / headerColor / textColor），
        //    取值口径与夹取范围都在 `Services/PartitionLook.cs`，改那里三端一起变。
        private readonly TextBox _styleBgBox = MakeTextBox(string.Empty, 92);
        private readonly TextBox _styleHeaderBox = MakeTextBox(string.Empty, 92);
        private readonly TextBox _styleTextColorBox = MakeTextBox(string.Empty, 92);
        private readonly Slider _styleOpacitySlider = MakeSlider(0, 1, 0.05);
        private readonly Slider _styleRadiusSlider = MakeSlider(0, PartitionLook.CornerRadiusRange.Max, 1);
        private readonly Slider _styleBlurSlider = MakeSlider(0, PartitionLook.BlurRange.Max, 1);
        private readonly TextBlock _styleOpacityValue = MakeValueLabel();
        private readonly TextBlock _styleRadiusValue = MakeValueLabel();
        private readonly TextBlock _styleBlurValue = MakeValueLabel();

        /// <summary>
        /// 哪些分区类型谈得上「视图」——与 mac 端 <c>usesViewMode</c> 严格同口径。
        /// 便签与待办是自由排版的容器，本来就没有网格 / 列表之分，给了就是个死开关。
        /// </summary>
        private static bool UsesViewMode(string type) =>
            type == "portal" || type == "collection";

        private PartitionSettingsDialog(PartitionModel model, Config config, Action onApplied)
        {
            _model = model;
            _config = config;
            _onApplied = onApplied;

            var (icon, text) = Services.PartitionTitle.Split(model.Title, model.Type);
            _icon = icon;

            Title = "分区设置";
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Topmost = true;
            SizeToContent = SizeToContent.Height;
            Width = 400;
            MaxHeight = 720;
            FontFamily = (FontFamily)Application.Current.Resources["FluentFontFamily"];

            // ── 头部 ───────────────────────────────────────────────
            var headerIcon = new TextBlock
            {
                Text = "\uE713",   // Fluent Settings
                FontFamily = (FontFamily)Application.Current.Resources["FluentIconFont"],
                FontSize = 15,
                Foreground = new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4)),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 8, 0)
            };
            var header = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 0, 0, 14)
            };
            header.Children.Add(headerIcon);
            header.Children.Add(new TextBlock
            {
                Text = "分区设置",
                FontSize = 14,
                FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF5)),
                VerticalAlignment = VerticalAlignment.Center
            });

            // ── 命名 ───────────────────────────────────────────────
            _titleBox = MakeTextBox(text, 140);
            _titleBox.MaxLength = MaxTitleChars;

            // ── 尺寸 ───────────────────────────────────────────────
            _widthBox = MakeTextBox(((int)Math.Round(model.Width)).ToString(), 54);
            _heightBox = MakeTextBox(((int)Math.Round(model.Height)).ToString(), 54);
            _widthBox.LostFocus += (_, _) => CommitSize();
            _heightBox.LostFocus += (_, _) => CommitSize();

            var sizeRow = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                VerticalAlignment = VerticalAlignment.Center
            };
            sizeRow.Children.Add(Stepper("宽", _widthBox, () => StepSize(0, -SizeStep), () => StepSize(0, SizeStep)));
            sizeRow.Children.Add(new Border { Width = 10 });
            sizeRow.Children.Add(Stepper("高", _heightBox, () => StepSize(1, -SizeStep), () => StepSize(1, SizeStep)));

            var autoFitBtn = MakeGhostButton("按内容自适应高度", () =>
            {
                // 自适应由「拥有分区窗口」的一侧执行 —— 设置面板不该直接去改别人的 Height。
                // 执行完再把结果回填到输入框，否则用户会以为按钮没反应。
                AutoFitRequested?.Invoke();
                _heightBox.Text = ((int)Math.Round(_model.Height)).ToString();
            });
            autoFitBtn.Margin = new Thickness(0, 8, 0, 0);
            autoFitBtn.HorizontalAlignment = HorizontalAlignment.Left;
            _autoFitBtn = autoFitBtn;

            // ── 行为 ───────────────────────────────────────────────
            _lockedCheck = MakeCheck("锁定该分区（位置与尺寸）", model.IsLocked);
            _pinCheck = MakeCheck("置顶显示（浮于普通窗口之上）", model.IsAlwaysOnTop);
            _collapseCheck = MakeCheck("折叠该分区", model.IsCollapsed);

            // 尺寸随锁定状态启用 / 禁用：**锁定就该真的锁住尺寸**，
            // 否则从设置面板里还能改宽高，「已锁定」就成了一句空话。
            _lockedCheck.Checked += (_, _) => UpdateSizeEnabled();
            _lockedCheck.Unchecked += (_, _) => UpdateSizeEnabled();

            // ── 默认视图（仅展示文件列表的三种分区）─────────────────────────
            //
            // 工具条上那枚 ⊞/☰ 按钮**确实能切换**视图并持久化，但它藏在每个分区的
            // 头部按钮里：用户要先知道有这个东西、还得逐个分区去点。
            // mac 的「分区设置 → 默认视图」是同一份 `viewMode` 的另一个入口 ——
            // 这里补的就是它，两处写同一个字段，因此不会互相打架。
            if (UsesViewMode(_model.Type))
            {
                _viewModeBox = new ComboBox
                {
                    Width = 96,
                    Height = 26,
                    // 只认两种取值，写错或空一律按 grid —— 记住的选择在下次打开时
                    // 必须还是那一副样子，不能因为落盘值脏就 jumps 到默认网格。
                    SelectedValuePath = "Tag"
                };
                _viewModeBox.Items.Add(new ComboBoxItem { Content = "网格", Tag = "grid" });
                _viewModeBox.Items.Add(new ComboBoxItem { Content = "列表", Tag = "list" });
                _viewModeBox.SelectedValue = _model.ViewMode == "list" ? "list" : "grid";
            }

            // ── 组装正文 ───────────────────────────────────────────
            // 尺寸行手写（不复用 Row 助手）：它的副标题要随锁定状态变化，
            // 必须保住对那个 TextBlock 的引用。
            var sizeTexts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            sizeTexts.Children.Add(new TextBlock
            {
                Text = "尺寸",
                FontSize = 12,
                FontWeight = FontWeights.Medium,
                Foreground = new SolidColorBrush(Colors.White)
            });
            _sizeHint = new TextBlock
            {
                Text = "宽 × 高（像素）",
                FontSize = 10,
                Margin = new Thickness(0, 2, 0, 0),
                TextWrapping = TextWrapping.Wrap,
                Foreground = new SolidColorBrush(Color.FromArgb(0x66, 0xFF, 0xFF, 0xFF))
            };
            sizeTexts.Children.Add(_sizeHint);

            var sizeGrid = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            sizeGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            sizeGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            sizeRow.SetValue(Grid.ColumnProperty, 1);
            sizeGrid.Children.Add(sizeTexts);
            sizeGrid.Children.Add(sizeRow);

            // 自适应按钮单独一行、靠左：放进 Row 助手会被塞到 Auto 列（= 靠右），
            // 与上方「尺寸」行的右对齐控件挤成一列，看起来像同一个控件的附属项。
            var autoFitRow = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            autoFitRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            autoFitRow.Children.Add(autoFitBtn);

            var body = new StackPanel();
            body.Children.Add(BlockTitle("基本"));
            body.Children.Add(Card(new UIElement[]
            {
                Row("名称", "最多 10 个字，图标保持不变", _titleBox),
                sizeGrid,
                autoFitRow
            }));

            body.Children.Add(BlockTitle("行为"));
            var behaviorItems = new List<UIElement>
            {
                _lockedCheck,
                _pinCheck,
                _collapseCheck
            };
            if (_viewModeBox != null)
            {
                // 放在三个开关之前：这三项是「状态」，而视图是「这个分区长什么样」，
                // 与上方「基本」一脉相承，插到末尾会像是从属于「折叠」。
                behaviorItems.Insert(0, Row("默认视图", "网格或列表（工具条 ⊞/☰ 可随时切换）", _viewModeBox));
            }
            body.Children.Add(Card(behaviorItems.ToArray()));

            var appearanceItems = BuildAppearanceBlock();
            if (appearanceItems.Count > 0)
            {
                body.Children.Add(BlockTitle("外观"));
                body.Children.Add(Card(appearanceItems.ToArray()));
            }

            // 初值必须在所有控件都建好之后才同步 —— 否则会去碰还没赋值的字段
            UpdateSizeEnabled();
            SyncStyleControls();

            var scroller = new ScrollViewer
            {
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Content = body
            };

            // ── 底部按钮 ───────────────────────────────────────────
            var cancelBtn = MakeGhostButton("取消", Close);
            cancelBtn.Width = 76;
            cancelBtn.Height = 30;
            cancelBtn.Margin = new Thickness(0, 0, 8, 0);

            var doneBtn = new Button
            {
                Content = "完成",
                Width = 76,
                Height = 30,
                IsDefault = true,
                Cursor = Cursors.Hand,
                Style = Application.Current.Resources["FluentPrimaryBtnStyle"] as Style
            };
            doneBtn.Click += (_, _) => ApplyAndClose();

            var footer = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 14, 0, 0)
            };
            footer.Children.Add(cancelBtn);
            footer.Children.Add(doneBtn);

            var stack = new StackPanel { Margin = new Thickness(20, 18, 20, 18) };
            stack.Children.Add(header);
            stack.Children.Add(scroller);
            stack.Children.Add(footer);

            Content = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0xF2, 0x1C, 0x1C, 0x22)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x38, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
                Child = stack,
                Effect = new System.Windows.Media.Effects.DropShadowEffect
                {
                    BlurRadius = 18,
                    ShadowDepth = 4,
                    Direction = 270,
                    Color = Colors.Black,
                    Opacity = 0.45
                }
            };

            // 无系统标题栏 → 手动支持拖动
            MouseDown += (_, e) =>
            {
                if (e.ChangedButton == MouseButton.Left) DragMove();
            };
        }

        /// <summary>请求「按内容自适应高度」——由拥有分区窗口的一侧执行。</summary>
        public Action? AutoFitRequested { get; set; }

        /// <summary>打开分区设置面板；点击「完成」且内容有变化时返回 true。</summary>
        public static bool Edit(PartitionModel model, Config config, Action onApplied, Action? onAutoFit = null)
        {
            var dlg = new PartitionSettingsDialog(model, config, onApplied) { AutoFitRequested = onAutoFit };
            return dlg.ShowDialog() == true;
        }

        // MARK: - 尺寸步进

        /// <summary>
        /// 依据锁定状态启用 / 禁用尺寸控件，并把「为什么不能改」直接写在副标题上。
        ///
        /// 分两种锁定来源分别措辞 —— 只说「已锁定」的话，分区锁用户会去翻全局设置，
        /// 屏幕锁用户会去翻分区标题栏，两边都找不到（对应 mac 端同一处理）。
        /// </summary>
        private void UpdateSizeEnabled()
        {
            bool screenLocked = _config.IsScreenLocked(_model.ScreenId);
            bool partitionLocked = _lockedCheck.IsChecked == true;
            bool canEdit = !screenLocked && !partitionLocked;

            _widthBox.IsEnabled = canEdit;
            _heightBox.IsEnabled = canEdit;
            _autoFitBtn.IsEnabled = canEdit;

            _sizeHint.Text = canEdit
                ? "宽 × 高（像素）"
                : screenLocked
                    ? "本屏已锁定：请先在导航栏或托盘菜单解锁本屏"
                    : "分区已锁定：取消上方「锁定该分区」后即可调整尺寸";
        }

        private void StepSize(int axis, double delta)
        {
            CommitSize();   // 先落定用户手输的值，再基于它加减
            double current = axis == 0 ? _model.Width : _model.Height;
            double next = axis == 0
                ? Math.Max(MinPartitionWidth, current + delta)
                : Math.Max(MinPartitionHeight, current + delta);

            if (axis == 0)
            {
                _model.Width = next;
                _widthBox.Text = ((int)Math.Round(next)).ToString();
            }
            else
            {
                _model.Height = next;
                _heightBox.Text = ((int)Math.Round(next)).ToString();
            }
        }

        private void CommitSize()
        {
            if (double.TryParse(_widthBox.Text.Trim(), out double w))
            {
                double clamped = Math.Max(MinPartitionWidth, w);
                _model.Width = clamped;
                _widthBox.Text = ((int)Math.Round(clamped)).ToString();
            }
            else
            {
                _widthBox.Text = ((int)Math.Round(_model.Width)).ToString();
            }

            if (double.TryParse(_heightBox.Text.Trim(), out double h))
            {
                double clamped = Math.Max(MinPartitionHeight, h);
                _model.Height = clamped;
                _heightBox.Text = ((int)Math.Round(clamped)).ToString();
            }
            else
            {
                _heightBox.Text = ((int)Math.Round(_model.Height)).ToString();
            }
        }

        // MARK: - 外观（分区级样式）

        /// <summary>
        /// 把 <c>Model.Style</c> 的当前值灌进控件。
        /// ⚠️ 三个滑块的「未设置」初值各不相同：不透明度跟随<b>全局</b>设置、圆角与模糊跟随
        /// <see cref="PartitionLook"/> 的默认值 —— 这样老分区打开面板看到的就是它现在的样子。
        /// </summary>
        private void SyncStyleControls()
        {
            var st = _model.Style;
            _styleBgBox.Text = st?.BgColor ?? string.Empty;
            _styleHeaderBox.Text = st?.HeaderColor ?? string.Empty;
            _styleTextColorBox.Text = st?.TextColor ?? string.Empty;

            _styleOpacitySlider.Value = PartitionLook.ClampBgOpacity(st?.BgOpacity ?? _config.PartitionBgOpacity);
            _styleRadiusSlider.Value = PartitionLook.ClampCornerRadius(st?.BorderRadius ?? PartitionLook.DefaultCornerRadius);
            _styleBlurSlider.Value = PartitionLook.ClampBlur(st?.BlurAmount ?? PartitionLook.DefaultBlurAmount);

            _styleOpacitySlider.ValueChanged += (_, _) => SyncStyleValueLabels();
            _styleRadiusSlider.ValueChanged += (_, _) => SyncStyleValueLabels();
            _styleBlurSlider.ValueChanged += (_, _) => SyncStyleValueLabels();
            SyncStyleValueLabels();
        }

        private void SyncStyleValueLabels()
        {
            _styleOpacityValue.Text = ((int)Math.Round(_styleOpacitySlider.Value * 100)) + "%";
            _styleRadiusValue.Text = ((int)Math.Round(_styleRadiusSlider.Value)) + "pt";
            _styleBlurValue.Text = ((int)Math.Round(_styleBlurSlider.Value)) + " / "
                                   + TierName(PartitionLook.TierFor(_styleBlurSlider.Value));
        }

        /// <summary>把档位翻成用户看得懂的词（mac / Electron 用同一套说法）。</summary>
        private static string TierName(PartitionLook.BlurTier tier) => tier switch
        {
            PartitionLook.BlurTier.None => "无",
            PartitionLook.BlurTier.UltraThin => "极薄",
            PartitionLook.BlurTier.Thin => "薄",
            _ => "常规"
        };

        /// <summary>外观卡片。返回空列表表示这个分区类型不适用（目前所有类型都适用）。</summary>
        private List<UIElement> BuildAppearanceBlock()
        {
            var items = new List<UIElement>
            {
                Row("背景色", "留空 = 跟随全局；支持 #RRGGBB", HexWithPalette(_styleBgBox, _styleBgBox)),
                SliderRow("不透明度", "背景遮罩的浓度，0% = 完全透明", _styleOpacitySlider, _styleOpacityValue),
                SliderRow("圆角", "0 = 直角方卡", _styleRadiusSlider, _styleRadiusValue),
                SliderRow("模糊", "系统毛玻璃强度（Windows 上按 Mica / Acrylic 分档）", _styleBlurSlider, _styleBlurValue),
                Row("标题色", "留空 = 跟随主题强调色", _styleHeaderBox),
                Row("正文色", "留空 = 跟随系统前景色", _styleTextColorBox)
            };

            var reset = MakeGhostButton("恢复默认（跟随全局）", () =>
            {
                _styleBgBox.Text = string.Empty;
                _styleHeaderBox.Text = string.Empty;
                _styleTextColorBox.Text = string.Empty;
                _styleOpacitySlider.Value = _config.PartitionBgOpacity;
                _styleRadiusSlider.Value = PartitionLook.DefaultCornerRadius;
                _styleBlurSlider.Value = PartitionLook.DefaultBlurAmount;
            });
            reset.HorizontalAlignment = HorizontalAlignment.Left;
            reset.Margin = new Thickness(0, 6, 0, 0);
            items.Add(reset);
            return items;
        }

        /// <summary>「滑块 + 数值」一行：数值放右侧，拖动时能看见当前值。</summary>
        private static UIElement SliderRow(string title, string subtitle, Slider slider, TextBlock valueLabel)
        {
            var wrap = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            slider.Width = 120;
            slider.VerticalAlignment = VerticalAlignment.Center;
            valueLabel.Margin = new Thickness(8, 0, 0, 0);
            wrap.Children.Add(slider);
            wrap.Children.Add(valueLabel);
            return Row(title, subtitle, wrap);
        }

        /// <summary>色值输入框 + 一排常用色快捷按钮（色板与 mac / Electron 同序）。</summary>
        private UIElement HexWithPalette(TextBox box, TextBox _)
        {
            var wrap = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            wrap.Children.Add(box);

            var palette = new WrapPanel { Width = 132, Margin = new Thickness(8, 0, 0, 0) };
            foreach (var hex in PartitionLook.Palette)
            {
                var swatch = new Border
                {
                    Width = 14,
                    Height = 14,
                    CornerRadius = new CornerRadius(3),
                    Margin = new Thickness(0, 0, 4, 4),
                    Cursor = Cursors.Hand,
                    Background = new SolidColorBrush(ParseHexColorCore(hex)),
                    BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)),
                    BorderThickness = new Thickness(1),
                    ToolTip = hex
                };
                swatch.MouseLeftButtonUp += (_, _) => box.Text = hex;
                palette.Children.Add(swatch);
            }
            wrap.Children.Add(palette);
            return wrap;
        }

        private static Slider MakeSlider(double min, double max, double tick)
        {
            return new Slider
            {
                Minimum = min,
                Maximum = max,
                TickFrequency = tick,
                IsSnapToTickEnabled = true,
                Width = 120,
                Foreground = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF5))
            };
        }

        private static TextBlock MakeValueLabel() => new()
        {
            FontSize = 11,
            MinWidth = 52,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF))
        };

        /// <summary>
        /// 归一 hex 输入：非法或空 → null（= 跟随全局 / 跟随系统）。
        /// <b>不抛异常</b>：用户手输的可能是「#fff」「红色」之类，静默回落比弹窗好。
        /// </summary>
        private static string? NormalizeHexOrNull(string? raw)
        {
            var s = (raw ?? string.Empty).Trim();
            if (s.Length == 0) return null;
            if (!s.StartsWith("#")) s = "#" + s;
            var body = s.Substring(1);
            if (body.Length != 3 && body.Length != 6 && body.Length != 8) return null;
            foreach (var c in body)
            {
                if (!Uri.IsHexDigit(c)) return null;
            }
            if (body.Length == 3)
            {
                s = "#" + body[0] + body[0] + body[1] + body[1] + body[2] + body[2];
            }
            return s.ToLowerInvariant();
        }

        private static Color ParseHexColorCore(string hex)
        {
            try { return (Color)ColorConverter.ConvertFromString(hex); }
            catch { return Colors.Gray; }
        }

        /// <summary>
        /// 回写外观。⚠️ <b>等于默认值的项一律写 null</b>，而不是写死数字：
        /// 写死之后将来调默认观感时，这些老分区会被自己当年落盘的值钉住升不了级。
        /// </summary>
        private void CommitStyle()
        {
            var st = _model.EditableStyle;
            st.BgColor = NormalizeHexOrNull(_styleBgBox.Text);
            st.HeaderColor = NormalizeHexOrNull(_styleHeaderBox.Text);
            st.TextColor = NormalizeHexOrNull(_styleTextColorBox.Text);

            double opacity = PartitionLook.ClampBgOpacity(_styleOpacitySlider.Value);
            double radius = PartitionLook.ClampCornerRadius(_styleRadiusSlider.Value);
            double blur = PartitionLook.ClampBlur(_styleBlurSlider.Value);

            st.BgOpacity = Math.Abs(opacity - _config.PartitionBgOpacity) < 0.005 ? null : opacity;
            st.BorderRadius = Math.Abs(radius - PartitionLook.DefaultCornerRadius) < 0.5 ? null : radius;
            st.BlurAmount = Math.Abs(blur - PartitionLook.DefaultBlurAmount) < 0.5 ? null : blur;

            // 一个键都没写 → 整个 style 不落盘（保持「完全跟随全局」）。
            if (st.IsEmpty) _model.Style = null;
        }

        private void ApplyAndClose()
        {
            CommitSize();

            string newText = _titleBox.Text.Trim();
            if (newText.Length > MaxTitleChars) newText = newText.Substring(0, MaxTitleChars);
            if (newText.Length == 0) newText = Services.PartitionTitle.Split(_model.Title, _model.Type).Text;
            _model.Title = Services.PartitionTitle.Compose(_icon, newText);

            _model.IsLocked = _lockedCheck.IsChecked == true;
            _model.IsAlwaysOnTop = _pinCheck.IsChecked == true;
            _model.IsCollapsed = _collapseCheck.IsChecked == true;

            // 只有建过这个控件才回写：其余类型的分区不该因为打开一次设置面板
            // 就被迫得到一个 ViewMode（便签/待办本来就用不上）。
            if (_viewModeBox != null)
            {
                _model.ViewMode = _viewModeBox.SelectedValue as string == "list" ? "list" : "grid";
            }

            CommitStyle();

            _config.Save();
            _onApplied();
            DialogResult = true;
            Close();
        }

        // MARK: - 小部件工厂

        private static TextBox MakeTextBox(string text, double width)
        {
            return new TextBox
            {
                Text = text,
                Width = width,
                Height = 26,
                Background = new SolidColorBrush(Color.FromArgb(0x15, 0xFF, 0xFF, 0xFF)),
                Foreground = new SolidColorBrush(Colors.White),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(1),
                FontSize = 11.5,
                Padding = new Thickness(6, 0, 6, 0),
                VerticalContentAlignment = VerticalAlignment.Center
            };
        }

        private static CheckBox MakeCheck(string label, bool isChecked)
        {
            return new CheckBox
            {
                Content = label,
                IsChecked = isChecked,
                Foreground = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF5)),
                FontSize = 12,
                Margin = new Thickness(0, 4, 0, 4)
            };
        }

        private Button MakeGhostButton(string label, Action onClick)
        {
            var btn = new Button
            {
                Content = label,
                Height = 26,
                Padding = new Thickness(10, 0, 10, 0),
                MinWidth = 48,
                Cursor = Cursors.Hand,
                FontSize = 11,
                Foreground = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF5)),
                Background = new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(1)
            };
            btn.Click += (_, _) => onClick();
            return btn;
        }

        /// <summary>「数字输入 + 减/加」组合，省得为宽高各写一遍。</summary>
        private UIElement Stepper(string label, TextBox box, Action onMinus, Action onPlus)
        {
            var wrap = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            wrap.Children.Add(new TextBlock
            {
                Text = label,
                FontSize = 11,
                Foreground = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 6, 0)
            });
            wrap.Children.Add(MakeGhostButton("−", onMinus));
            box.Margin = new Thickness(4, 0, 4, 0);
            wrap.Children.Add(box);
            wrap.Children.Add(MakeGhostButton("+", onPlus));
            return wrap;
        }

        private static TextBlock BlockTitle(string text) => new()
        {
            Text = text,
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)),
            Margin = new Thickness(4, 0, 0, 6)
        };

        private static Border Card(IEnumerable<UIElement> children)
        {
            var stack = new StackPanel();
            foreach (var child in children) stack.Children.Add(child);

            return new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0x0C, 0xFF, 0xFF, 0xFF)),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(14, 12, 14, 12),
                Margin = new Thickness(0, 0, 0, 14),
                Child = stack
            };
        }

        private static UIElement Row(string title, string subtitle, UIElement control)
        {
            var grid = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            if (!string.IsNullOrEmpty(title))
            {
                texts.Children.Add(new TextBlock
                {
                    Text = title,
                    FontSize = 12,
                    FontWeight = FontWeights.Medium,
                    Foreground = new SolidColorBrush(Colors.White)
                });
            }
            if (!string.IsNullOrEmpty(subtitle))
            {
                texts.Children.Add(new TextBlock
                {
                    Text = subtitle,
                    FontSize = 10,
                    Margin = new Thickness(0, 2, 0, 0),
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = new SolidColorBrush(Color.FromArgb(0x66, 0xFF, 0xFF, 0xFF))
                });
            }

            control.SetValue(Grid.ColumnProperty, 1);
            grid.Children.Add(texts);
            grid.Children.Add(control);
            return grid;
        }
    }
}
