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
- **App detail (tabbed)**: selecting an app opens a tabbed view — no long scroll:
  - **Overview**: headline stats (total events, unique clients, live-patch
    count), events-by-type, and the patches currently live on the latest
    release with inline rollout/withdraw controls.
  - **Releases**: full release history with per-platform status, patches per
    release (loaded lazily when you expand a release), and channels.
  - **Analytics**: a grid of inline-SVG charts, loaded lazily the first time
    the tab is opened. Endpoints that a given server build hasn't implemented
    degrade gracefully to "Not available." rather than breaking.
  - **Team**: app collaborators (list, add, remove). Organization-level
    membership is managed from the sidebar **Team** section.
- **Rollout control**: per-patch channel selector + 0–100% slider/number input
  that calls the rollout admin endpoint; withdraw and withdraw-with-rollback
  buttons (each behind a confirm dialog).
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
- `GET  /api/v1/users/me`
- `GET  /api/v1/apps`
- `POST /api/v1/apps`
- `GET  /api/v1/apps/{appId}/releases`
- `GET  /api/v1/apps/{appId}/releases/{releaseId}/patches`
- `GET  /api/v1/apps/{appId}/channels`
- `GET  /api/v1/apps/{appId}/metrics`
- `GET  /api/v1/apps/{appId}/analytics/patch-adoption`
- `GET  /api/v1/apps/{appId}/analytics/unique-users`
- `GET  /api/v1/apps/{appId}/analytics/version-distribution`
- `GET  /api/v1/apps/{appId}/analytics/activity-heatmap`
- `GET  /api/v1/apps/{appId}/analytics/active-hours`
- `GET  /api/v1/apps/{appId}/analytics/new-devices`
- `GET  /api/v1/apps/{appId}/analytics/patch-installs`
- `GET  /api/v1/apps/{appId}/analytics/patch-downloads`

Admin actions (Bearer):

- `GET    /admin/apps/{appId}/collaborators`
- `POST   /admin/apps/{appId}/collaborators?email=&role=`
- `DELETE /admin/apps/{appId}/collaborators/{userId}`
- `POST   /admin/apps/{appId}/patches/{patchId}/rollout?channel=&percent=`
- `POST   /admin/apps/{appId}/patches/{patchId}/withdraw?channel=&rollback=`

All of the above are implemented by `lib/src/api.dart`. The console still calls
each analytics endpoint defensively: any that a given server build does not
implement (or that returns no data) renders as "Not available." in its
Analytics card rather than breaking the page.
