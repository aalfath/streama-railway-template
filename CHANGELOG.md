# Changelog

## 1.11.3-1 (2026-11-23)

First release of this template.

- Streama 1.11.3 (official release JAR, SHA-256 `7c2ea2eb7e99b8e859cc52066d065fd34956aafe50b7a68855e746aee32101fc`) on `eclipse-temurin:8u512-b09-jre-noble@sha256:1cb6e62b74eae0a883db43a50fa73f4e1a4df9c9bc7217ca7d0346c2205c6994`.
- All state (H2 database, remember-me key, uploads) on the `/data` volume.
- First boot replaces upstream's default `admin`/`admin` password with `ADMIN_PASSWORD` before the public port opens.
- JVM sized to the container's memory limit; exits non-zero on OutOfMemoryError so Railway restarts it.
