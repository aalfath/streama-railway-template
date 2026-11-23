# Streama: self-hosted personal media streaming server.
# Upstream publishes no current Docker image (Docker Hub gkiko/streama stops at 1.10.3),
# so this builds from the official release JAR, pinned by version and SHA-256,
# on the official Eclipse Temurin 8 JRE (Streama is a Grails 3 / Java 8 app), pinned by digest.
FROM eclipse-temurin:8u512-b09-jre-noble@sha256:1cb6e62b74eae0a883db43a50fa73f4e1a4df9c9bc7217ca7d0346c2205c6994

ARG STREAMA_VERSION=1.11.3
ARG STREAMA_SHA256=7c2ea2eb7e99b8e859cc52066d065fd34956aafe50b7a68855e746aee32101fc

RUN apt-get update \
 && apt-get install -y --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /app /data \
 && curl -fsSL -o /app/streama.jar "https://github.com/streamaserver/streama/releases/download/v${STREAMA_VERSION}/streama-${STREAMA_VERSION}.jar" \
 && echo "${STREAMA_SHA256}  /app/streama.jar" | sha256sum -c -

COPY start.sh /app/start.sh
RUN chmod 755 /app/start.sh

# /data holds the H2 database, the remember-me key and uploaded media (mount a volume here).
WORKDIR /data
ENV STREAMA_DATA_DIR=/data
EXPOSE 8080
CMD ["/app/start.sh"]
