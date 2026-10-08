using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DeskIsle.Models;
using DeskIsle.Services;

namespace DeskIsle.Views
{
    public partial class NewPartitionDialog : Window
    {
        public PartitionModel? ResultPartition { get; private set; }

        private readonly Config? _config;
        private string _selectedType = "portal";
        private string _selectedFolder = Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
        private string _lastDefaultTitle = "映射文件夹";

        public NewPartitionDialog(Config? config = null)
        {
            _config = config;
            InitializeComponent();

            TitleTextBox.Text = "映射文件夹";
            FolderPathPreview.Text = _selectedFolder;
            ValidateForm();

            MouseDown += (s, e) =>
            {
                if (e.ChangedButton == System.Windows.Input.MouseButton.Left) DragMove();
            };
        }

        private void Type_Checked(object sender, RoutedEventArgs e)
        {
            if (TypePortal.IsChecked == true) SetType("portal", "📁", "映射文件夹");
            else if (TypeTodo.IsChecked == true) SetType("todo", "✅", "待办清单");
            else if (TypeNotes.IsChecked == true) SetType("notes", "📝", "随手便签");
        }

        private void SetType(string type, string icon, string defaultLabel)
        {
            _selectedType = type;
            TitleIconPrefix.Text = icon + " ";

            if (TitleTextBox.Text == _lastDefaultTitle || string.IsNullOrWhiteSpace(TitleTextBox.Text))
            {
                TitleTextBox.Text = defaultLabel;
            }
            _lastDefaultTitle = defaultLabel;

            bool needsFolder = (type == "portal");
            FolderRow.Visibility = needsFolder ? Visibility.Visible : Visibility.Collapsed;

            ValidateForm();
        }

        private void TitleTextBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            ValidateForm();
        }

        private void ValidateForm()
        {
            if (TitleTextBox == null || CreateBtn == null) return;

            string text = TitleTextBox.Text.Trim();
            bool isTitleValid = !string.IsNullOrEmpty(text);

            bool isFolderValid = true;
            if (_selectedType == "portal")
            {
                isFolderValid = !string.IsNullOrEmpty(_selectedFolder) && Directory.Exists(_selectedFolder);
            }

            if (!isTitleValid)
            {
                TitleInputBorder.BorderBrush = new SolidColorBrush(Color.FromRgb(255, 85, 85));
                TitleErrorText.Visibility = Visibility.Visible;
            }
            else
            {
                TitleInputBorder.BorderBrush = new SolidColorBrush(Color.FromArgb(40, 255, 255, 255));
                TitleErrorText.Visibility = Visibility.Collapsed;
            }

            CreateBtn.IsEnabled = isTitleValid && isFolderValid;
            CreateBtn.Opacity = CreateBtn.IsEnabled ? 1.0 : 0.45;
        }

        private void SelectFolder_Click(object sender, RoutedEventArgs e)
        {
            using var fbd = new System.Windows.Forms.FolderBrowserDialog
            {
                Description = "选择映射文件夹",
                UseDescriptionForTitle = true,
                SelectedPath = _selectedFolder
            };

            if (fbd.ShowDialog() == System.Windows.Forms.DialogResult.OK)
            {
                _selectedFolder = fbd.SelectedPath;
                FolderPathPreview.Text = _selectedFolder;
                ValidateForm();
            }
        }

        private void QuickPathDesktop_Click(object sender, RoutedEventArgs e)
        {
            _selectedFolder = Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
            FolderPathPreview.Text = _selectedFolder;
            ValidateForm();
        }

        private void QuickPathDownloads_Click(object sender, RoutedEventArgs e)
        {
            string user = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            _selectedFolder = Path.Combine(user, "Downloads");
            FolderPathPreview.Text = _selectedFolder;
            ValidateForm();
        }

        private void QuickPathDocuments_Click(object sender, RoutedEventArgs e)
        {
            _selectedFolder = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
            FolderPathPreview.Text = _selectedFolder;
            ValidateForm();
        }

        private void Create_Click(object sender, RoutedEventArgs e)
        {
            string cleanTitle = TitleTextBox.Text.Trim();
            if (string.IsNullOrEmpty(cleanTitle)) return;
            if (cleanTitle.Length > 10) cleanTitle = cleanTitle[..10];

            // 默认宽度按「本对话框所在显示器」的宽度计算（多屏分辨率不同）
            double initialWidth = 280;
            double initialHeight = 200;
            if (_config != null)
            {
                var workArea = MonitorService.WorkingAreaDIP(MonitorService.ScreenOf(this), this);
                initialWidth = _config.CalculateStandardWidth(workArea.Width);
                // 高度取 max(默认, 最小)，两个偏好都要先夹本屏上限
                // （只夹最小、不夹默认时，填 5000 仍会造出比屏幕还高的分区）
                initialHeight = Math.Max(
                    PartitionMetrics.ClampedPartitionHeight(_config.DefaultPartitionHeight, workArea.Height),
                    PartitionMetrics.ClampedUserMinHeight(_config.MinPartitionHeight, workArea.Height));
            }
            ResultPartition = new PartitionModel
            {
                Id = Guid.NewGuid().ToString(),
                Type = _selectedType,
                Title = $"{TitleIconPrefix.Text.Trim()} {cleanTitle}",
                Width = initialWidth,
                // 取 max 而非直接用默认高度：用户把「最小高度」抬到默认高度之上时，
                // 新建分区若仍按默认高度生成，一落地就违反自己的下限设定。
                Height = initialHeight,
                FolderPath = (_selectedType == "portal") ? _selectedFolder : null
            };

            if (_selectedType == "todo")
            {
                ResultPartition.Todos.Add(new TodoItem
                {
                    Id = "todo-1",
                    Text = "整理桌面核心工作文件",
                    Completed = false,
                    Priority = "high"
                });
                ResultPartition.Todos.Add(new TodoItem
                {
                    Id = "todo-2",
                    Text = "规划项目迭代功能",
                    Completed = true,
                    Priority = "medium"
                });
            }

            DialogResult = true;
            Close();
        }

        private void Cancel_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
            Close();
        }
    }
}
