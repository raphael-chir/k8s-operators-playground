# AI Builder image: the existing Python service (bind-mounted at runtime, like the Playground image) plus a PINNED Claude Code CLI.
# No credential is ever copied or baked in: the login lives in the `claude-auth` volume (compose.yaml).
# No Docker, Kind, kubectl or Helm is installed on purpose: this container drives a code-writing agent and nothing else.
# Build context: ./ai-builder (see compose.yaml); this directory has no .dockerignore, and nothing is COPY'd.
FROM node:22-bookworm-slim

# Claude Code from npm (needs Node >= 22). 2.1.326 is the version whose flags the AI Builder was written against.
ARG CLAUDE_CODE_VERSION=2.1.326

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 bash ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g --no-fund --no-audit "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

# The unprivileged user "node" (uid/gid 1000) owns the home directory that the `claude-auth` volume replaces.
# /workspace and /publish only hold mount points: compose.yaml mounts the repository directories there read-only.
ENV HOME=/home/builder \
    CLAUDE_CONFIG_DIR=/home/builder/.claude \
    PYTHONDONTWRITEBYTECODE=1 \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    BROWSER=true
RUN mkdir -p /home/builder/.claude /workspace /publish /state \
 && chown -R 1000:1000 /home/builder /state \
 && chmod 700 /home/builder

USER 1000:1000
WORKDIR /workspace
EXPOSE 8099
CMD ["python3", "/workspace/ai-builder/server.py"]
