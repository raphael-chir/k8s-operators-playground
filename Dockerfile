FROM debian:bookworm-slim

ARG TARGETARCH
ARG DOCKER_VERSION=28.0.1
ARG KIND_VERSION=v0.33.0
# k3d: the optional second internal provider (usecase.yaml provider.name k3d); Kind stays the default
ARG K3D_VERSION=v5.9.0
ARG KUBECTL_VERSION=v1.37.2
ARG HELM_VERSION=v4.3.1
# OpenShift CLI (oc), pinned to the OpenShift 4.22 line (works against OpenShift Local); kubectl stays the Kubernetes client
ARG OC_VERSION=4.22.14
ARG TTYD_VERSION=1.7.7
ARG CNPG_PLUGIN_VERSION=1.30.1
# EDB PG4K plugin (kubectl cnp): official release assets of github.com/EnterpriseDB/kubectl-cnp
ARG EDB_CNP_PLUGIN_VERSION=1.30.1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash bash-completion git curl jq ca-certificates procps less vim python3-fastapi python3-uvicorn \
 && rm -rf /var/lib/apt/lists/*

# TARGETARCH is amd64 or arm64; each upstream names architectures differently.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) DOCKER_ARCH=x86_64;  TTYD_ARCH=x86_64;  CNPG_ARCH=x86_64;  OC_ARCH=x86_64  ;; \
      arm64) DOCKER_ARCH=aarch64; TTYD_ARCH=aarch64; CNPG_ARCH=arm64;  OC_ARCH=aarch64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/docker-${DOCKER_VERSION}.tgz" \
      | tar -xz --strip-components=1 -C /usr/local/bin docker/docker; \
    curl -fsSL -o /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${TARGETARCH}"; \
    curl -fsSL -o /usr/local/bin/k3d "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-${TARGETARCH}"; \
    curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
      | tar -xz --strip-components=1 -C /usr/local/bin "linux-${TARGETARCH}/helm"; \
    curl -fsSL -o /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}"; \
    curl -fsSL "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_PLUGIN_VERSION}/kubectl-cnpg_${CNPG_PLUGIN_VERSION}_linux_${CNPG_ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin kubectl-cnpg; \
    curl -fsSL "https://github.com/EnterpriseDB/kubectl-cnp/releases/download/v${EDB_CNP_PLUGIN_VERSION}/kubectl-cnp_${EDB_CNP_PLUGIN_VERSION}_linux_${CNPG_ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin kubectl-cnp; \
    curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/${OC_ARCH}/clients/ocp/${OC_VERSION}/openshift-client-linux.tar.gz" \
      | tar -xz -C /usr/local/bin oc; \
    chmod +x /usr/local/bin/*; \
    oc version --client

# Shell completions (written at build time), and the hook that loads the project shell config.
RUN docker completion bash > /etc/bash_completion.d/docker \
 && kubectl completion bash > /etc/bash_completion.d/kubectl \
 && oc completion bash > /etc/bash_completion.d/oc \
 && helm completion bash > /etc/bash_completion.d/helm \
 && kind completion bash > /etc/bash_completion.d/kind \
 && k3d completion bash > /etc/bash_completion.d/k3d \
 && mkdir -p /root/.history \
 && echo "[ -f /workspace/engine/shell/bashrc ] && . /workspace/engine/shell/bashrc" > /root/.bashrc \
 && echo 'if filereadable("/workspace/engine/shell/vimrc") | source /workspace/engine/shell/vimrc | endif' > /root/.vimrc

ENV TERM=xterm-256color
WORKDIR /workspace
EXPOSE 7681 8080

# Joins the kind network before ttyd starts (see engine/entrypoint.sh); the project is bind-mounted.
ENTRYPOINT ["bash", "/workspace/engine/entrypoint.sh"]

# ttyd listens on all container interfaces; compose publishes it on 127.0.0.1 only.
# Each connection starts its own Bash through engine/terminal.sh (no session manager): --url-arg lets the page pass
# ?arg=<usecase>, which the script validates; no argument = the Playground terminal. scrollback is xterm.js's own
# history (ttyd default 1000); selection and copy/paste are xterm.js defaults.
CMD ["ttyd", "--writable", "--url-arg", "--port", "7681", "--cwd", "/workspace", "-t", "scrollback=10000", "bash", "/workspace/engine/terminal.sh"]
