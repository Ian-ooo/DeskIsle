using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace DeskIsle.Views
{
    /// <summary>
    /// 一行文字的输入弹窗（命名布局预设用）。
    ///
    /// 为什么不用 WinForms 的 <c>Interaction.InputBox</c>：它需要额外引用
    /// <c>Microsoft.VisualBasic</c>，而本项目刻意保持**零第三方依赖**；
    /// 也为什么不用「自动按时间戳命名」省掉弹窗：布局预设的核心价值就是
    /// 「给这套摆法起个我记得住的名字」，省掉命名等于省掉这个功能的用途。
    ///
    /// 纯代码构建、不走 XAML，与其它新增面板保持同一风格。
    /// </summary>
    public sealed class TextPromptDialog : Window
    {
        private readonly TextBox _input;
        private string _result = string.Empty;

        private TextPromptDialog(string title, string prompt, string initial, string confirmLabel)
        {
            Title = title;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Topmost = true;
            SizeToContent = SizeToContent.Height;
            Width = 360;
            FontFamily = (FontFamily)Application.Current.Resources["FluentFontFamily"];

            var head = new TextBlock
            {
                Text = title,
                FontSize = 13.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF5))
            };
            var hint = new TextBlock
            {
                Text = prompt,
                FontSize = 10.5,
                Margin = new Thickness(0, 4, 0, 0),
                TextWrapping = TextWrapping.Wrap,
                Foreground = new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF))
            };

            _input = new TextBox
            {
                Text = initial,
                Height = 30,
                Margin = new Thickness(0, 12, 0, 0),
                Background = new SolidColorBrush(Color.FromArgb(0x18, 0xFF, 0xFF, 0xFF)),
                Foreground = new SolidColorBrush(Colors.White),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(1),
                FontSize = 12.5,
                Padding = new Thickness(8, 0, 8, 0),
                VerticalContentAlignment = VerticalAlignment.Center,
                MaxLength = 24
            };
            _input.SelectAll();

            var cancelBtn = new Button
            {
                Content = "取消",
                Width = 72,
                Height = 28,
                Margin = new Thickness(0, 0, 8, 0),
                Cursor = Cursors.Hand,
                FontSize = 11.5,
                Foreground = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF5)),
                Background = new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(0)
            };
            cancelBtn.Click += (_, _) => { DialogResult = false; Close(); };

            var okBtn = new Button
            {
                Content = confirmLabel,
                Width = 72,
                Height = 28,
                IsDefault = true,
                Cursor = Cursors.Hand,
                Style = Application.Current.Resources["FluentPrimaryBtnStyle"] as Style
            };
            okBtn.Click += (_, _) => Accept();

            var footer = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 16, 0, 0)
            };
            footer.Children.Add(cancelBtn);
            footer.Children.Add(okBtn);

            var stack = new StackPanel { Margin = new Thickness(20, 18, 20, 18) };
            stack.Children.Add(head);
            stack.Children.Add(hint);
            stack.Children.Add(_input);
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

            Loaded += (_, _) =>
            {
                _input.Focus();
                Keyboard.Focus(_input);
            };

            MouseDown += (_, e) =>
            {
                if (e.ChangedButton == MouseButton.Left) DragMove();
            };
        }

        private void Accept()
        {
            string text = _input.Text.Trim();
            if (text.Length == 0) return;   // 空名字无从识别，直接不响应「确定」
            _result = text;
            DialogResult = true;
            Close();
        }

        /// <summary>
        /// 弹出输入框。用户点「确定」且输入非空时返回输入内容，否则返回 null。
        /// </summary>
        public static string? Prompt(string title, string prompt, string initial = "", string confirmLabel = "确定")
        {
            var dlg = new TextPromptDialog(title, prompt, initial, confirmLabel);
            return dlg.ShowDialog() == true ? dlg._result : null;
        }
    }
}
