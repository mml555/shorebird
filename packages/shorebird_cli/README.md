# Shorebird CLI

The Shorebird command-line allows developers to interact with various Shorebird services.

> **This is a fork build.** The version is `1.6.114+selfhost.1` — upstream
> 1.6.114 plus the changes listed in [`RELEASE_NOTES.md`](../../RELEASE_NOTES.md).
> It is not published to pub.dev, and `shorebird upgrade` does not track it.
>
> The CLI is service-agnostic: it talks to whichever control plane it is pointed
> at. To point it at a self-hosted server instead of `api.shorebird.dev`, see
> [`selfhost/INTEGRATION.md`](../../selfhost/INTEGRATION.md).

See https://docs.shorebird.dev for more information. That documents upstream's
hosted service, but the command surface is the same.

`shorebird help` shows high-level help on available commands.

`shorebird <command> --help` can show information about a specific command.
