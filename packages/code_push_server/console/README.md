# Shorebird Console

A self-contained web console for a self-hosted Shorebird `code_push_server`
control plane. It drives the JSON API and the authenticated `/admin` surface
using an API key the operator pastes in (sent as `Authorization: Bearer <key>`),
exactly like the built-in `/admin/ui` page.

Everything is in a single file: [`index.html`](./index.html). All CSS and JS
are inlined, charts are drawn with inline SVG, and there are **no external
CDNs, no network dependencies, and no build step**.

## Features

- **Connection**: enter a *server base URL* and an *API key*; both persist in
  `localStorage`. A status indicator shows connected / connecting / error.
- **Organizations & apps**: lists your orgs, lists apps, and a create-app form.
- **App detail**: releases with per-platform status, patches per release
  (loaded lazily when you expand a release), and channels.
- **Rollout control**: per-patch channel selector + 0–100% slider/number input
  that calls the rollout admin endpoint; withdraw and withdraw-with-rollback
  buttons (each behind a confirm dialog); add-collaborator form.
- **Metrics**: total events, unique clients, events-by-type, a per-patch
  downloads/installs/unique-clients table, and an inline-SVG bar chart.
- **Analytics**: if the optional analytics endpoints return data, they render
  as a table + chart; otherwise those sections are silently omitted.
- **Theme**: follows the OS light/dark preference, with a manual toggle
  (auto → light → dark).

## Serving it

The console talks to the API purely from the browser, so it can be served any
way you like. Enter the API base URL in the top **Server base URL** field.

### Same-origin (recommended, once the server serves it)

The main server is expected to add a route that serves this directory at
`/console/` (for example mapping `GET /console/…` to the files here). When
opened that way, leave **Server base URL** blank — requests go to the same
origin the page was loaded from, so no CORS configuration is needed.

### Standalone static server

Serve this directory with any static file server and point the base URL field
at your `code_push_server`:

```bash
cd packages/code_push_server/console
python3 -m http.server 8888
# then open http://localhost:8888/ and set the base URL to e.g.
#   http://localhost:8080
```

### `file://`

You can also just open `index.html` directly in a browser and set the base URL
to your server. Note that browsers apply CORS to cross-origin `fetch`, so the
server (or a proxy in front of it) must allow the request origin. Same-origin
serving avoids this entirely.

> **CORS note:** for the standalone and `file://` modes the server must return
> permissive CORS headers (or sit behind a proxy that does). The current
> `code_push_server` does not add CORS headers, so same-origin serving under
> `/console/` is the intended deployment.

## Authentication

Paste any credential the server accepts as a bearer token: an issued API key
(`sb_api_…`), the bootstrap API key, or an OAuth access token (JWT). It is
stored in `localStorage` on your machine and sent only to the base URL you
configure.

## API endpoints used

Read-only / provisioning (Bearer):

- `GET  /api/v1/organizations`
- `GET  /api/v1/apps`
- `POST /api/v1/apps`
- `GET  /api/v1/apps/{appId}/releases`
- `GET  /api/v1/apps/{appId}/releases/{releaseId}/patches` *(see caveat below)*
- `GET  /api/v1/apps/{appId}/channels`
- `GET  /api/v1/apps/{appId}/metrics`
- `GET  /api/v1/apps/{appId}/analytics/patch-adoption` *(optional)*
- `GET  /api/v1/apps/{appId}/analytics/version-distribution` *(optional)*
- `GET  /api/v1/apps/{appId}/analytics/active-users` *(optional)*

Admin actions (Bearer):

- `POST /admin/apps/{appId}/patches/{patchId}/rollout?channel=&percent=`
- `POST /admin/apps/{appId}/patches/{patchId}/withdraw?channel=&rollback=`
- `POST /admin/apps/{appId}/collaborators?email=&role=`

### Endpoints the console assumes but the server may not yet implement

The console degrades gracefully (shows "no data"/"unavailable" instead of
breaking) when these are missing:

- **`GET /api/v1/apps/{appId}/releases/{releaseId}/patches`** — not present in
  the current `lib/src/api.dart` router. Without it, the per-release patch list
  (and therefore the inline rollout/withdraw controls) stays empty. Expected
  shape: `{"patches":[{"id":…,"number":…,"status":…}]}`.
- **`GET /api/v1/apps/{appId}/analytics/patch-adoption`**,
  **`/analytics/version-distribution`**, **`/analytics/active-users`** — not
  implemented yet. The console requests them defensively and renders whatever
  array it finds (looks for `points` / `entries` / `data` / `items` / `rows`,
  falling back to the first array-valued field); if they 404 the Analytics
  section is omitted.
