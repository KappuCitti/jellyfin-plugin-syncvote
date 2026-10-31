using System.Collections.Generic;
using KappuCitti.Plugin.SyncVote.Infrastructure;
using Xunit;

namespace KappuCitti.Plugin.SyncVote.Tests;

public class LocalizationTests
{
    private static readonly string[] Available = { "de", "en", "es", "et", "fr", "it" };

    [Theory]
    [InlineData("it-IT", "it")]
    [InlineData("it_IT", "it")]
    [InlineData("IT", "it")]
    [InlineData("en-US", "en")]
    [InlineData("en-GB", "en")]
    [InlineData("es-ES", "es")]
    [InlineData("es_MX", "es")]
    [InlineData("de-DE", "de")]
    [InlineData("de-AT", "de")]
    [InlineData("DE", "de")]
    [InlineData("fr-FR", "fr")]
    [InlineData("fr_CA", "fr")]
    [InlineData("et-EE", "et")]
    // Swiss locales: the written language is the standard one (Swiss German has no standard spelling of its own).
    [InlineData("de-CH", "de")]
    [InlineData("fr-CH", "fr")]
    [InlineData("it-CH", "it")]
    public void TheServerLanguageIsUsedWhenThePluginIsOnAuto(string serverCulture, string expected)
    {
        Assert.Equal(expected, Localization.Pick("Auto", serverCulture, Available));
        Assert.Equal(expected, Localization.Pick(null, serverCulture, Available));
        Assert.Equal(expected, Localization.Pick("auto", serverCulture, Available));
    }

    [Theory]
    [InlineData("pt-BR")]
    [InlineData("zh-CN")]
    [InlineData("gsw-CH")]
    [InlineData("")]
    [InlineData(null)]
    public void AnUnknownServerLanguageFallsBackToEnglish(string? serverCulture)
    {
        Assert.Equal("en", Localization.Pick("Auto", serverCulture, Available));
    }

    [Fact]
    public void TheLanguageSetInThePluginWinsOverTheServer()
    {
        Assert.Equal("it", Localization.Pick("it", "en-US", Available));
        Assert.Equal("en", Localization.Pick("EN", "it-IT", Available));
        Assert.Equal("es", Localization.Pick("es", "de-DE", Available));
        Assert.Equal("de", Localization.Pick("de", "es-ES", Available));
    }

    [Fact]
    public void AnUnknownLanguageInThePluginFollowsTheServer()
    {
        Assert.Equal("it", Localization.Pick("xx", "it-IT", Available));
        Assert.Equal("en", Localization.Pick("xx", "pt-BR", Available));
    }

    [Fact]
    public void LaterLayersOverrideEarlierOnesAndKeepTheRest()
    {
        var english = new Dictionary<string, string> { ["a"] = "A", ["b"] = "B" };
        var italian = new Dictionary<string, string> { ["b"] = "Bi" };

        var merged = Localization.Merge(new IReadOnlyDictionary<string, string>[] { english, italian });

        Assert.Equal("A", merged["a"]);
        Assert.Equal("Bi", merged["b"]);
    }
}
