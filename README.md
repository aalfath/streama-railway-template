[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/streama?utm_medium=integration&utm_source=button&utm_campaign=streama)

# Streama on Railway

One-click [Railway](https://railway.com) template for [Streama](https://github.com/streamaserver/streama), a self-hosted, Netflix-style streaming server for your own movies, TV shows and videos.

## What it deploys

| Service | What it does |
|---|---|
| **Streama** (built from this repo) | Streama **1.11.3** (official release JAR, SHA-256 checked) on the official Eclipse Temurin 8 JRE (`eclipse-temurin:8u512-b09-jre-noble`, pinned by digest). Web UI on Railway's `PORT`, health check `/login/auth`. |
| Volume `/data` | The embedded H2 database (`streamadb.mv.db`), the remember-me signing key and every uploaded video, poster and subtitle (`/data/media`). |

Upstream publishes no current Docker image (Docker Hub `gkiko/streama` stops at 1.10.3), so this repo builds one from the release JAR. Upstream's own Docker profile uses the same embedded H2 database, so no separate database service is needed.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `ADMIN_PASSWORD` | `${{secret(24)}}` | Password for the `admin` user, set on first boot. Read it in the service's **Variables** tab. Changing it later has no effect: change the password in Streama's profile page instead. |
| `PORT` | `8080` | Port Streama listens on. |

## After deploy

1. Open the public URL and sign in as `admin` with `ADMIN_PASSWORD`.
2. In **Admin → Settings**, the upload directory (`/data/media`) and base URL are already set. Add a free [TheMovieDB API key](https://www.themoviedb.org/settings/api) if you want posters and descriptions fetched for you.
3. Upload videos in **Admin → Manage Content**, invite users under **Admin → Users** (invites by email need SMTP, see below; otherwise create users directly).

Video files live on the Railway volume, so the volume size limits your library (it depends on your Railway plan; you can grow it in the volume settings). Browsers play MP4 (H.264/AAC) and WebM directly; other formats need converting first.

## How the first boot works

Upstream Streama creates the user `admin` with the password `admin` on first start. `start.sh` starts it bound to `127.0.0.1` only, changes that password to `ADMIN_PASSWORD`, presets the upload directory and base URL, stops it, and only then starts it on the public port. The default password is never reachable from the internet. A marker file on the volume makes this run once.

## Memory

`start.sh` reads the container's memory limit. At 800 MB or less (for example Railway's 0.5 GB Free/Trial services) it runs the JVM with a 200 MB heap and a small metaspace, code cache and thread pool; Streama then uses about 350–400 MB. With more memory it uses 60% of the limit for the heap. If the JVM runs out of memory it exits non-zero, so Railway restarts it. Set `JAVA_OPTS` to add your own JVM flags.

## Optional features

- **Email** (invitations, password reset): set `grails.mail.*` Spring properties, for example `JAVA_OPTS=-Dgrails.mail.host=smtp.example.com -Dgrails.mail.port=587 -Dgrails.mail.username=... -Dgrails.mail.password=...`.
- **Subtitles search**: add an OpenSubtitles.com API key in Admin → Settings.
- **LDAP login**: see upstream's `application.yml` comments.

## Updates

This template builds from this GitHub repo, so Railway shows an "update available" notice when the Streama version here is bumped on `main`. Read [CHANGELOG.md](CHANGELOG.md) before you apply an update. Your data stays on the `/data` volume across updates; Streama migrates its H2 database on start.

## Local run

```sh
docker build -t streama-railway .
docker run -p 8080:8080 -e ADMIN_PASSWORD=change-me-please -v streama-data:/data streama-railway
```
