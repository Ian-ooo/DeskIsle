using System.IO;
using DeskIsle.Services;
using Xunit;

namespace DeskIsle.Tests
{
    public class PortalDirectoryScanTests
    {
        [Fact]
        public void HiddenEntryIsSkipped()
        {
            bool made = PortalDirectoryScan.TryMake(
                @"C:\desk\secret.txt",
                "secret.txt",
                FileAttributes.Hidden,
                isPhysicalDirectory: false,
                size: 4,
                modifiedUtcTicks: 1,
                out _);
            Assert.False(made);
        }

        [Fact]
        public void PackageIsNotAFolder()
        {
            Assert.True(PortalDirectoryScan.TryMake(
                @"C:\desk\Foo.app",
                "Foo.app",
                FileAttributes.Directory,
                isPhysicalDirectory: true,
                size: -1,
                modifiedUtcTicks: 1,
                out var entry));
            Assert.False(entry.IsDirectory);
            Assert.True(entry.IsPackage);
            Assert.Equal(-1, entry.Size);
        }

        [Fact]
        public void PlainFileKeepsSize()
        {
            Assert.True(PortalDirectoryScan.TryMake(
                @"C:\desk\note.txt",
                "note.txt",
                FileAttributes.Normal,
                isPhysicalDirectory: false,
                size: 12,
                modifiedUtcTicks: 99,
                out var entry));
            Assert.False(entry.IsDirectory);
            Assert.False(entry.IsPackage);
            Assert.Equal(12, entry.Size);
            Assert.Equal(".txt", entry.Extension);
            Assert.Equal(99, entry.ModifiedUtcTicks);
        }

        [Fact]
        public void SameTreatsSizeOrMtimeChangeAsDifferent()
        {
            var a = new[]
            {
                new PortalDirEntry("a.txt", @"C:\a.txt", false, false, 1, ".txt", 10),
            };
            var bigger = new[]
            {
                new PortalDirEntry("a.txt", @"C:\a.txt", false, false, 2, ".txt", 10),
            };
            var touched = new[]
            {
                new PortalDirEntry("a.txt", @"C:\a.txt", false, false, 1, ".txt", 11),
            };
            Assert.True(PortalDirectoryScan.Same(a, a));
            Assert.False(PortalDirectoryScan.Same(a, bigger));
            Assert.False(PortalDirectoryScan.Same(a, touched));
        }

        [Fact]
        public void ReadSortsAndSkipsHidden()
        {
            string root = Path.Combine(Path.GetTempPath(), "deskisle-scan-" + Path.GetRandomFileName());
            Directory.CreateDirectory(root);
            try
            {
                File.WriteAllText(Path.Combine(root, "b.txt"), "bb");
                File.WriteAllText(Path.Combine(root, "a.txt"), "a");
                string hidden = Path.Combine(root, "secret.txt");
                File.WriteAllText(hidden, "nope");
                File.SetAttributes(hidden, File.GetAttributes(hidden) | FileAttributes.Hidden);
                Directory.CreateDirectory(Path.Combine(root, "Foo.app"));

                var entries = PortalDirectoryScan.Read(root);

                Assert.Equal(3, entries.Count);
                Assert.Equal("a.txt", entries[0].Name);
                Assert.Equal(1, entries[0].Size);
                Assert.Equal("b.txt", entries[1].Name);
                Assert.Equal(2, entries[1].Size);
                Assert.Equal("Foo.app", entries[2].Name);
                Assert.True(entries[2].IsPackage);
                Assert.False(entries[2].IsDirectory);
            }
            finally
            {
                try { Directory.Delete(root, true); } catch { }
            }
        }

        [Fact]
        public void MissingDirectoryIsEmpty()
        {
            string gone = Path.Combine(Path.GetTempPath(), "deskisle-missing-" + Path.GetRandomFileName());
            Assert.Empty(PortalDirectoryScan.Read(gone));
            Assert.Empty(PortalDirectoryScan.Read(""));
            Assert.Empty(PortalDirectoryScan.Read(null));
        }
    }
}
