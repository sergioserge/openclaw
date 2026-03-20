FROM node:22-bookworm@sha256:cd7bcd2e7a1e6f72052feb023c7f6b722205d3fcab7bbcbd2d1bfdab10b1e935

# Install Bun (pinned version with checksum verification)
RUN curl -fsSL https://github.com/oven-sh/bun/releases/download/bun-v1.3.10/bun-linux-x64.zip -o /tmp/bun.zip \
    && echo "f57bc0187e39623de716ba3a389fda5486b2d7be7131a980ba54dc7b733d2e08  /tmp/bun.zip" | sha256sum -c - \
    && unzip /tmp/bun.zip -d /tmp/bun-release \
    && mkdir -p /root/.bun/bin \
    && mv /tmp/bun-release/bun-linux-x64/bun /root/.bun/bin/bun \
    && chmod 755 /root/.bun/bin/bun \
    && rm -rf /tmp/bun.zip /tmp/bun-release
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app
RUN chown node:node /app

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY --chown=node:node package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY --chown=node:node ui/package.json ./ui/package.json
COPY --chown=node:node patches ./patches
COPY --chown=node:node scripts ./scripts

USER node
# Reduce OOM risk on low-memory hosts during dependency installation.
# Docker builds on small VMs may otherwise fail with "Killed" (exit 137).
RUN NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile

# Optionally install Chromium and Xvfb for browser automation.
# Build with: docker build --build-arg OPENCLAW_INSTALL_BROWSER=1 ...
# Adds ~300MB but eliminates the 60-90s Playwright install on every container start.
# Must run after pnpm install so playwright-core is available in node_modules.
USER root
ARG OPENCLAW_INSTALL_BROWSER=""
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb && \
      mkdir -p /home/node/.cache/ms-playwright && \
      PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright \
      node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
      chown -R node:node /home/node/.cache/ms-playwright && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

USER node
COPY --chown=node:node . .
RUN pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

# Expose the CLI binary without requiring npm global writes as non-root.
USER root
RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw \
 && chmod 755 /app/openclaw.mjs

# Install gog (Google Workspace CLI) — linux_amd64; update version here when upgrading.
RUN curl -fsSL https://github.com/steipete/gogcli/releases/download/v0.11.0/gogcli_0.11.0_linux_amd64.tar.gz \
    | tar -xz -C /usr/local/bin gog \
    && chmod 755 /usr/local/bin/gog

ENV NODE_ENV=production

# Entrypoint: runs as root to fix bind-mount ownership, then drops to node.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh

# Stay as root so the entrypoint can chown the mounted config dir.
# The entrypoint itself drops to 'node' (uid 1000) before exec-ing the gateway.
USER root

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","openclaw.mjs","gateway","--allow-unconfigured","--bind","lan"]
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
