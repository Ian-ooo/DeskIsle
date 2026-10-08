using System;
using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DeskIsle.Native;

namespace DeskIsle.Services
{
    /// <summary>
    /// Windows 原生文件关联图标高速抽取与缓存服务
    /// </summary>
    public static class IconService
    {
        private static readonly ConcurrentDictionary<string, ImageSource?> _cache = new(StringComparer.OrdinalIgnoreCase);
        private static ImageSource? _defaultFolderIcon;

        /// <summary>
        /// 获取文件或文件夹的 Windows 原生小图标 (16x16)
        /// </summary>
        public static ImageSource? GetIcon(string path, bool isDirectory)
        {
            try
            {
                if (isDirectory)
                {
                    if (_defaultFolderIcon != null) return _defaultFolderIcon;

                    var shinfo = new Win32.SHFILEINFO();
                    IntPtr hImg = Win32.SHGetFileInfo(
                        "dummy_dir",
                        Win32.FILE_ATTRIBUTE_DIRECTORY,
                        ref shinfo,
                        (uint)Marshal.SizeOf(shinfo),
                        Win32.SHGFI_ICON | Win32.SHGFI_SMALLICON | Win32.SHGFI_USEFILEATTRIBUTES);

                    if (hImg != IntPtr.Zero && shinfo.hIcon != IntPtr.Zero)
                    {
                        var bs = Imaging.CreateBitmapSourceFromHIcon(
                            shinfo.hIcon,
                            Int32Rect.Empty,
                            BitmapSizeOptions.FromEmptyOptions());
                        bs.Freeze();
                        Win32.DestroyIcon(shinfo.hIcon);
                        _defaultFolderIcon = bs;
                        return bs;
                    }
                    return null;
                }

                string ext = Path.GetExtension(path).ToLowerInvariant();

                // 针对含有独立图标的特殊文件 (.exe, .lnk, .ico, .url) 优先按完整路径抽取
                bool hasCustomIcon = ext is ".exe" or ".lnk" or ".ico" or ".url";
                string cacheKey = hasCustomIcon && File.Exists(path) ? path : (string.IsNullOrEmpty(ext) ? ".__default__" : ext);

                if (_cache.TryGetValue(cacheKey, out var cached))
                {
                    return cached;
                }

                var info = new Win32.SHFILEINFO();
                IntPtr res;

                if (hasCustomIcon && File.Exists(path))
                {
                    res = Win32.SHGetFileInfo(
                        path,
                        0,
                        ref info,
                        (uint)Marshal.SizeOf(info),
                        Win32.SHGFI_ICON | Win32.SHGFI_SMALLICON);
                }
                else
                {
                    res = Win32.SHGetFileInfo(
                        string.IsNullOrEmpty(ext) ? "file" : ext,
                        Win32.FILE_ATTRIBUTE_NORMAL,
                        ref info,
                        (uint)Marshal.SizeOf(info),
                        Win32.SHGFI_ICON | Win32.SHGFI_SMALLICON | Win32.SHGFI_USEFILEATTRIBUTES);
                }

                if (res != IntPtr.Zero && info.hIcon != IntPtr.Zero)
                {
                    var bitmap = Imaging.CreateBitmapSourceFromHIcon(
                        info.hIcon,
                        Int32Rect.Empty,
                        BitmapSizeOptions.FromEmptyOptions());
                    bitmap.Freeze();
                    Win32.DestroyIcon(info.hIcon);

                    _cache[cacheKey] = bitmap;
                    return bitmap;
                }

                _cache[cacheKey] = null;
                return null;
            }
            catch
            {
                return null;
            }
        }
    }
}
