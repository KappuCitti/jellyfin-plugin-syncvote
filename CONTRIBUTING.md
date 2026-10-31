# Contributing

Thanks for helping! Bug reports, ideas, test reports and pull requests are all welcome.

## Where to go

- **Something does not work:** open an [issue](https://github.com/KappuCitti/jellyfin-plugin-syncvote/issues/new/choose) with
  the *Bug report* form.
- **You tried it and want to tell how it went:** use the *Test report* form, good news is useful too.
- **A question, or an idea that is still vague:** use [Discussions](https://github.com/KappuCitti/jellyfin-plugin-syncvote/discussions).
  A concrete idea can be a *Feature request* issue; the [open issues](https://github.com/KappuCitti/jellyfin-plugin-syncvote/issues) show what is already planned
  (look for `good first issue` and `help wanted` if you want to lend a hand).

## Report a problem

The bug form asks for the following; it helps to have it at hand:

- your Jellyfin version and the SyncVote package version (Dashboard → Plugins);
- the web interface layout (new or classic) and the browser;
- what you did, what you expected and what happened;
- the browser console (F12) and the Jellyfin server log if something failed.

## Send a change

1. Fork, then create a branch for one change.
2. Build and test it as described in the [development guide](docs/DEVELOPMENT.md): `dotnet test KappuCitti.Plugin.SyncVote.Tests`,
   and build **all** Jellyfin generations with `./build.ps1`, because a change that works for one can break another.
3. Add a test when you can: a unit test for rules, an end-to-end check for behavior ([tests/e2e](tests/e2e/README.md)).
4. Keep texts in the translation files (`Web/i18n/<language>.json`, every file with the same keys as `en.json`).
5. Open the pull request and say what it changes and how you tried it.

> [!NOTE]
> Code comments, commit messages and documentation are in English.

## Translations

The texts are in `KappuCitti.Plugin.SyncVote/Web/i18n/<language>.json`. Italian is by the maintainer; Spanish, German, French and
Estonian were translated with AI and may be imperfect, so corrections are very welcome (a pull request on the file, or a comment
on the [translation issue](https://github.com/KappuCitti/jellyfin-plugin-syncvote/issues/5)). To add a language, copy `en.json`,
translate the values (the keys and the `{0}` placeholders stay), and add the language to the **Language** list of
`Configuration/configPage.html`; two unit tests check both.

## Not planned

SyncVote stays small on purpose. These are out of scope, so a request for them is likely to be declined:

- Tournament brackets and other complex voting modes.
- Recommendations across libraries and external rating services.
- Jellyfin 10.8 and older: the plugin needs `IPluginServiceRegistrator`, which appeared in 10.9.

## AI assistance

SyncVote is developed with the help of AI coding tools. The maintainer reviews, tests and takes responsibility for everything
that is merged, and [AGENTS.md](AGENTS.md) is the public brief those tools work from. You are welcome to use AI tools for your
own contributions too, as long as you have read, understood and tried what you submit.

Releases are made by the maintainer.
