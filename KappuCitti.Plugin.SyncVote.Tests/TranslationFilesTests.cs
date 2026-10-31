using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using Xunit;

namespace KappuCitti.Plugin.SyncVote.Tests;

public class TranslationFilesTests
{
    private static string WebFolder
    {
        get
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "KappuCitti.Plugin.SyncVote", "Web")))
            {
                dir = dir.Parent;
            }

            return Path.Combine(dir!.FullName, "KappuCitti.Plugin.SyncVote", "Web");
        }
    }

    private static Dictionary<string, string> Load(string language)
        => JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Path.Combine(WebFolder, "i18n", language + ".json")))!;

    public static IEnumerable<object[]> Languages => Directory.GetFiles(Path.Combine(WebFolder, "i18n"), "*.json")
        .Select(f => new object[] { Path.GetFileNameWithoutExtension(f) });

    [Theory]
    [MemberData(nameof(Languages))]
    public void EveryLanguageDefinesTheSameKeysAsEnglish(string language)
    {
        var english = Load("en").Keys.ToHashSet();
        var other = Load(language).Keys.ToHashSet();

        Assert.Empty(english.Except(other));
        Assert.Empty(other.Except(english));
    }

    [Theory]
    [MemberData(nameof(Languages))]
    public void PlaceholdersMatchEnglish(string language)
    {
        var english = Load("en");
        foreach (var pair in Load(language))
        {
            var expected = Regex.Matches(english[pair.Key], @"\{\d+\}").Select(m => m.Value).OrderBy(x => x);
            var actual = Regex.Matches(pair.Value, @"\{\d+\}").Select(m => m.Value).OrderBy(x => x);
            Assert.True(expected.SequenceEqual(actual), $"{language}: placeholders of '{pair.Key}' differ from English");
        }
    }

    [Fact]
    public void EveryKeyTheClientAsksForExists()
    {
        var english = Load("en");
        var script = File.ReadAllText(Path.Combine(WebFolder, "syncvote.js"));
        var keys = Regex.Matches(script, @"\bt\(""([A-Za-z0-9_.]+)""").Select(m => m.Groups[1].Value).Distinct();

        Assert.Empty(keys.Where(k => !english.ContainsKey(k)));
    }

    [Theory]
    [MemberData(nameof(Languages))]
    public void EveryLanguageIsOfferedInTheSettingsPage(string language)
    {
        var page = File.ReadAllText(Path.Combine(WebFolder, "..", "Configuration", "configPage.html"));
        var options = Regex.Matches(page, @"<option value=""([a-z]+)"">").Select(m => m.Groups[1].Value);

        Assert.Contains(language, options);
    }

    [Theory]
    [InlineData("es")]
    [InlineData("de")]
    [InlineData("fr")]
    [InlineData("et")]
    [InlineData("it")]
    public void ATranslationIsNotACopyOfEnglish(string language)
    {
        // A few words (names, "min") may be the same in another language: most of the texts must not be.
        var english = Load("en");
        var other = Load(language);
        var same = english.Keys.Count(k => english[k] == other[k]);

        Assert.True(same < english.Count / 10, $"{language}: {same} of {english.Count} texts are identical to English");
    }

    [Fact]
    public void EveryKeyOfTheSettingsPageExists()
    {
        var english = Load("en");
        var page = File.ReadAllText(Path.Combine(WebFolder, "..", "Configuration", "configPage.html"));
        var keys = Regex.Matches(page, @"data-i18n=""([A-Za-z0-9_.]+)""").Select(m => m.Groups[1].Value).Distinct();

        Assert.Empty(keys.Where(k => !english.ContainsKey(k)));
    }
}
