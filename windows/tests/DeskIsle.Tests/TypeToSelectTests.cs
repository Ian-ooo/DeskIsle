using System.Collections.Generic;
using DeskIsle.Services;
using Xunit;

namespace DeskIsle.Tests
{
    public class TypeToSelectTests
    {
        private readonly List<(string name, string path)> _candidates = new()
        {
            ("Apple.txt", @"C:\path\Apple.txt"),
            ("Avocado.png", @"C:\path\Avocado.png"),
            ("Banana.doc", @"C:\path\Banana.doc"),
            ("Book.pdf", @"C:\path\Book.pdf"),
            ("Cat.mp4", @"C:\path\Cat.mp4")
        };

        [Fact]
        public void InitialSingleCharacterMatch()
        {
            var (buf, match) = TypeToSelect.Resolve("b", "", 0, 10, _candidates, null);
            Assert.Equal("b", buf);
            Assert.Equal(@"C:\path\Banana.doc", match);
        }

        [Fact]
        public void PrefixAccumulationMatch()
        {
            var (buf1, match1) = TypeToSelect.Resolve("b", "", 0, 10, _candidates, null);
            Assert.Equal("b", buf1);
            Assert.Equal(@"C:\path\Banana.doc", match1);

            var (buf2, match2) = TypeToSelect.Resolve("o", buf1, 10, 10.2, _candidates, match1);
            Assert.Equal("bo", buf2);
            Assert.Equal(@"C:\path\Book.pdf", match2);
        }

        [Fact]
        public void SingleCharacterRepeatCycles()
        {
            var (buf1, match1) = TypeToSelect.Resolve("a", "", 0, 10, _candidates, null);
            Assert.Equal("a", buf1);
            Assert.Equal(@"C:\path\Apple.txt", match1);

            var (buf2, match2) = TypeToSelect.Resolve("a", buf1, 10, 10.3, _candidates, match1);
            Assert.Equal("a", buf2);
            Assert.Equal(@"C:\path\Avocado.png", match2);

            var (buf3, match3) = TypeToSelect.Resolve("a", buf2, 10.3, 10.5, _candidates, match2);
            Assert.Equal("a", buf3);
            Assert.Equal(@"C:\path\Apple.txt", match3);
        }

        [Fact]
        public void TimeoutResetsBuffer()
        {
            var (buf1, _) = TypeToSelect.Resolve("a", "", 0, 10, _candidates, null);
            Assert.Equal("a", buf1);

            var (buf2, match2) = TypeToSelect.Resolve("c", buf1, 10, 11.5, _candidates, null);
            Assert.Equal("c", buf2);
            Assert.Equal(@"C:\path\Cat.mp4", match2);
        }

        [Fact]
        public void ArrowNavigation()
        {
            Assert.Equal(0, TypeToSelect.NextIndex(null, TypeToSelectDirection.Down, 5));
            Assert.Equal(4, TypeToSelect.NextIndex(null, TypeToSelectDirection.Up, 5));

            Assert.Equal(2, TypeToSelect.NextIndex(1, TypeToSelectDirection.Down, 5));
            Assert.Equal(0, TypeToSelect.NextIndex(1, TypeToSelectDirection.Up, 5));
            Assert.Equal(0, TypeToSelect.NextIndex(0, TypeToSelectDirection.Up, 5));
            Assert.Equal(4, TypeToSelect.NextIndex(4, TypeToSelectDirection.Down, 5));

            // Grid 3 columns
            Assert.Equal(4, TypeToSelect.NextIndex(1, TypeToSelectDirection.Down, 5, 3));
            Assert.Equal(1, TypeToSelect.NextIndex(4, TypeToSelectDirection.Up, 5, 3));
        }
    }
}
