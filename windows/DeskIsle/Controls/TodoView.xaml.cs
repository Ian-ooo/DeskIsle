using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DeskIsle.Models;

namespace DeskIsle.Controls
{
    public partial class TodoView : UserControl
    {
        private PartitionModel? _partition;
        private Action? _onDataChanged;

        public TodoView()
        {
            InitializeComponent();
        }

        private bool _isCompletedCollapsed = true;

        public void BindData(PartitionModel partition, Action onDataChanged)
        {
            _partition = partition;
            _onDataChanged = onDataChanged;
            _filterMode = _partition.TodoFilterMode ?? "all";
            _isCompletedCollapsed = _partition.IsCompletedCollapsed;
            UpdateView();
        }

        private string _filterMode = "all";

        private void FilterBtn_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement fe && fe.Tag is string tag)
            {
                _filterMode = tag;
                if (_partition != null)
                {
                    _partition.TodoFilterMode = tag;
                    _onDataChanged?.Invoke();
                }
                UpdateView();
            }
        }

        private void UpdateView()
        {
            if (_partition == null) return;
            var uncompleted = _partition.Todos.Where(t => !t.Completed);
            var completed = _partition.Todos.Where(t => t.Completed);

            if (_filterMode == "active")
            {
                completed = Enumerable.Empty<TodoItem>();
            }
            else if (_filterMode == "high")
            {
                uncompleted = uncompleted.Where(t => t.Priority == "high");
                completed = completed.Where(t => t.Priority == "high");
            }

            var uncompletedList = uncompleted.ToList();
            var completedList = completed.ToList();

            TodoItemsControl.ItemsSource = uncompletedList;
            CompletedItemsControl.ItemsSource = completedList;

            bool isEmpty = uncompletedList.Count == 0 && completedList.Count == 0;
            EmptyStatePanel.Visibility = isEmpty ? Visibility.Visible : Visibility.Collapsed;
            TodoScrollViewer.Visibility = isEmpty ? Visibility.Collapsed : Visibility.Visible;

            bool hasCompleted = completedList.Count > 0;
            ClearCompletedBtn.Visibility = _partition.Todos.Any(t => t.Completed) ? Visibility.Visible : Visibility.Collapsed;
            CompletedSectionHeader.Visibility = hasCompleted ? Visibility.Visible : Visibility.Collapsed;
            CompletedTitle.Text = $"已完成 ({completedList.Count})";
            UpdateCompletedVisibility();

            TodoItemsControl.Items.Refresh();
            CompletedItemsControl.Items.Refresh();
        }

        private void CompletedHeader_Click(object sender, MouseButtonEventArgs e)
        {
            _isCompletedCollapsed = !_isCompletedCollapsed;
            if (_partition != null)
            {
                _partition.IsCompletedCollapsed = _isCompletedCollapsed;
                _onDataChanged?.Invoke();
            }
            UpdateCompletedVisibility();
        }

        private void UpdateCompletedVisibility()
        {
            CompletedChevron.Text = _isCompletedCollapsed ? "\uE76C" : "\uE70D";
            CompletedItemsControl.Visibility = _isCompletedCollapsed ? Visibility.Collapsed : Visibility.Visible;
        }

        private void InputBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter)
            {
                string text = InputBox.Text.Trim();
                if (!string.IsNullOrEmpty(text) && _partition != null)
                {
                    _partition.Todos.Add(new TodoItem
                    {
                        Id = Guid.NewGuid().ToString(),
                        Text = text,
                        Completed = false,
                        Priority = "medium"
                    });
                    InputBox.Text = string.Empty;
                    UpdateView();
                    _onDataChanged?.Invoke();
                }
            }
        }

        private void CheckBox_Click(object sender, RoutedEventArgs e)
        {
            UpdateView();
            _onDataChanged?.Invoke();
        }

        private void Priority_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement elem && elem.DataContext is TodoItem item)
            {
                CyclePriority(item);
            }
        }

        private void CyclePriority(TodoItem item)
        {
            item.Priority = item.Priority switch
            {
                "high" => "medium",
                "medium" => "low",
                _ => "high"
            };
            UpdateView();
            _onDataChanged?.Invoke();
        }

        private void DeleteTodo_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement elem && elem.DataContext is TodoItem item && _partition != null)
            {
                _partition.Todos.Remove(item);
                UpdateView();
                _onDataChanged?.Invoke();
            }
        }

        private void ClearCompleted_Click(object sender, RoutedEventArgs e)
        {
            if (_partition != null)
            {
                _partition.Todos.RemoveAll(t => t.Completed);
                UpdateView();
                _onDataChanged?.Invoke();
            }
        }

        private void DisplayText_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ClickCount == 2 && sender is TextBlock tb && tb.Parent is Grid grid)
            {
                StartInlineEdit(tb, grid);
                e.Handled = true;
            }
        }

        private void StartInlineEdit(TextBlock tb, Grid grid)
        {
            if (grid.Children.OfType<TextBox>().FirstOrDefault() is TextBox editBox && tb.DataContext is TodoItem item)
            {
                tb.Visibility = Visibility.Collapsed;
                editBox.Visibility = Visibility.Visible;
                editBox.Text = item.Text;
                editBox.Focus();
                editBox.SelectAll();
            }
        }

        private void EditBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (sender is TextBox editBox && editBox.Parent is Grid grid && editBox.DataContext is TodoItem item)
            {
                if (e.Key == Key.Enter)
                {
                    CommitInlineEdit(editBox, grid, item);
                    e.Handled = true;
                }
                else if (e.Key == Key.Escape)
                {
                    CancelInlineEdit(editBox, grid);
                    e.Handled = true;
                }
            }
        }

        private void EditBox_LostFocus(object sender, RoutedEventArgs e)
        {
            if (sender is TextBox editBox && editBox.Parent is Grid grid && editBox.DataContext is TodoItem item)
            {
                CommitInlineEdit(editBox, grid, item);
            }
        }

        private void CommitInlineEdit(TextBox editBox, Grid grid, TodoItem item)
        {
            if (editBox.Visibility != Visibility.Visible) return;
            string newText = editBox.Text.Trim();
            if (!string.IsNullOrEmpty(newText) && newText != item.Text)
            {
                item.Text = newText;
                _onDataChanged?.Invoke();
            }
            editBox.Visibility = Visibility.Collapsed;
            if (grid.Children.OfType<TextBlock>().FirstOrDefault() is TextBlock tb)
            {
                tb.Visibility = Visibility.Visible;
            }
            TodoItemsControl.Items.Refresh();
        }

        private void CancelInlineEdit(TextBox editBox, Grid grid)
        {
            editBox.Visibility = Visibility.Collapsed;
            if (grid.Children.OfType<TextBlock>().FirstOrDefault() is TextBlock tb)
            {
                tb.Visibility = Visibility.Visible;
            }
        }

        private void ContextMenuToggle_Click(object sender, RoutedEventArgs e)
        {
            if (sender is MenuItem mi && mi.DataContext is TodoItem item)
            {
                item.Completed = !item.Completed;
                UpdateView();
                _onDataChanged?.Invoke();
            }
        }

        private void ContextMenuPriority_Click(object sender, RoutedEventArgs e)
        {
            if (sender is MenuItem mi && mi.DataContext is TodoItem item)
            {
                CyclePriority(item);
            }
        }

        private void ContextMenuSetHighPriority_Click(object sender, RoutedEventArgs e) => SetPriority(sender, "high");
        private void ContextMenuSetMediumPriority_Click(object sender, RoutedEventArgs e) => SetPriority(sender, "medium");
        private void ContextMenuSetLowPriority_Click(object sender, RoutedEventArgs e) => SetPriority(sender, "low");

        private void SetPriority(object sender, string priority)
        {
            if (sender is MenuItem mi && mi.DataContext is TodoItem item)
            {
                item.Priority = priority;
                UpdateView();
                _onDataChanged?.Invoke();
            }
        }

        private void ContextMenuEdit_Click(object sender, RoutedEventArgs e)
        {
            if (sender is MenuItem mi && mi.DataContext is TodoItem item)
            {
                // 遍历 UI 树找到对应的 ItemBorder
                var container = TodoItemsControl.ItemContainerGenerator.ContainerFromItem(item) as FrameworkElement;
                if (container != null)
                {
                    var textBlock = FindVisualChild<TextBlock>(container, "DisplayText");
                    var grid = textBlock?.Parent as Grid;
                    if (textBlock != null && grid != null)
                    {
                        StartInlineEdit(textBlock, grid);
                    }
                }
            }
        }

        private static T? FindVisualChild<T>(DependencyObject parent, string name) where T : FrameworkElement
        {
            int count = VisualTreeHelper.GetChildrenCount(parent);
            for (int i = 0; i < count; i++)
            {
                var child = VisualTreeHelper.GetChild(parent, i);
                if (child is T element && element.Name == name) return element;
                var found = FindVisualChild<T>(child, name);
                if (found != null) return found;
            }
            return null;
        }

        private Point _dragStartPoint;

        private void ItemBorder_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            // 如果点在复选框、文本编辑框、删除按钮上，不触发拖拽
            if (e.OriginalSource is DependencyObject dep)
            {
                if (FindVisualParent<CheckBox>(dep) != null ||
                    FindVisualParent<TextBox>(dep) != null ||
                    FindVisualParent<Button>(dep) != null)
                {
                    return;
                }
            }
            _dragStartPoint = e.GetPosition(null);
        }

        private void ItemBorder_PreviewMouseMove(object sender, MouseEventArgs e)
        {
            if (e.LeftButton == MouseButtonState.Pressed && sender is Border border && border.DataContext is TodoItem item)
            {
                Point pos = e.GetPosition(null);
                Vector diff = _dragStartPoint - pos;
                if (Math.Abs(diff.X) > SystemParameters.MinimumHorizontalDragDistance ||
                    Math.Abs(diff.Y) > SystemParameters.MinimumVerticalDragDistance)
                {
                    var data = new DataObject("TodoItem", item.Id);
                    DragDrop.DoDragDrop(border, data, DragDropEffects.Move);
                }
            }
        }

        private void ItemBorder_DragOver(object sender, DragEventArgs e)
        {
            if (e.Data.GetDataPresent("TodoItem"))
            {
                e.Effects = DragDropEffects.Move;
                if (sender is Border b)
                {
                    b.BorderBrush = Application.Current.TryFindResource("AccentFillBrush") as Brush ?? Brushes.DodgerBlue;
                }
                e.Handled = true;
            }
        }

        private void ItemBorder_DragLeave(object sender, DragEventArgs e)
        {
            if (sender is Border b)
            {
                b.BorderBrush = Brushes.Transparent;
            }
        }

        private void ItemBorder_Drop(object sender, DragEventArgs e)
        {
            if (sender is Border b)
            {
                b.BorderBrush = Brushes.Transparent;
            }

            if (e.Data.GetDataPresent("TodoItem") && sender is Border targetBorder && targetBorder.DataContext is TodoItem targetItem && _partition != null)
            {
                string sourceId = (string)e.Data.GetData("TodoItem");
                if (sourceId != targetItem.Id)
                {
                    var sourceItem = _partition.Todos.FirstOrDefault(t => t.Id == sourceId);
                    if (sourceItem != null)
                    {
                        int fromIdx = _partition.Todos.IndexOf(sourceItem);
                        int toIdx = _partition.Todos.IndexOf(targetItem);
                        if (fromIdx >= 0 && toIdx >= 0 && fromIdx != toIdx)
                        {
                            _partition.Todos.RemoveAt(fromIdx);
                            _partition.Todos.Insert(toIdx, sourceItem);
                            UpdateView();
                            _onDataChanged?.Invoke();
                            e.Handled = true;
                        }
                    }
                }
            }
        }

        private static T? FindVisualParent<T>(DependencyObject child) where T : DependencyObject
        {
            var parent = VisualTreeHelper.GetParent(child);
            while (parent != null)
            {
                if (parent is T typed) return typed;
                parent = VisualTreeHelper.GetParent(parent);
            }
            return null;
        }

        private void UserControl_DragOver(object sender, DragEventArgs e)
        {
            if (e.Data.GetDataPresent(DataFormats.FileDrop))
            {
                e.Effects = DragDropEffects.Copy;
                e.Handled = true;
            }
        }

        private void UserControl_Drop(object sender, DragEventArgs e)
        {
            if (e.Data.GetDataPresent(DataFormats.FileDrop) && _partition != null)
            {
                string[] files = (string[])e.Data.GetData(DataFormats.FileDrop);
                foreach (string f in files)
                {
                    string name = Path.GetFileName(f);
                    _partition.Todos.Add(new TodoItem
                    {
                        Id = Guid.NewGuid().ToString(),
                        Text = $"处理: {name}",
                        Completed = false,
                        Priority = "high"
                    });
                }
                UpdateView();
                _onDataChanged?.Invoke();
            }
        }
    }
}
