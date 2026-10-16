FROM alpine:3.24.1

ARG TARGETARCH

ARG TALOS_VERSION=v1.14.0
ARG KUBECTL_VERSION=v1.37.0
ARG ZARF_VERSION=v0.85.0
ARG CRANE_VERSION=v0.22.0
ARG HUBBLE_VERSION=v1.19.4
ARG OPENBAO_VERSION=2.6.2
ARG OPENBAO_SHA256_AMD64=8dc11cc5fca0b539a9e352727dacb4e2d304daffcf9a66e0718ac325a20d05aa
ARG OPENBAO_SHA256_ARM64=1b408e01f3565ac0cbcb88d637dca271d0515148fb72efdeff4473a34fa50c4e

# ---------------------------------------------------------------------------
# Base tools
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Base tools
# ---------------------------------------------------------------------------
RUN apk add --no-cache \
    bash \
    ca-certificates \
    ripgrep \
    curl \
    git \
    go \
    nodejs \
    npm \
    chromium \
    nss-tools \
    bind-tools \
    tar \
    gzip \
    unzip \
    jq \
    openssl \
    sudo \
    helm \
    docker \
    docker-cli-compose \
    docker-cli-buildx \
    apache2-utils \
    && update-ca-certificates

# ---------------------------------------------------------------------------
# Development user
# ---------------------------------------------------------------------------
RUN addgroup -g 1000 dev \
    && adduser \
        -D \
        -u 1000 \
        -G dev \
        -s /bin/bash \
        dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

# ---------------------------------------------------------------------------
# Validate architecture
# ---------------------------------------------------------------------------
RUN case "${TARGETARCH}" in \
        amd64|arm64) ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac

# ---------------------------------------------------------------------------
# talosctl
# ---------------------------------------------------------------------------
RUN curl -fsSL \
      "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-${TARGETARCH}" \
      -o /usr/local/bin/talosctl \
    && chmod +x /usr/local/bin/talosctl

# ---------------------------------------------------------------------------
# kubectl
# ---------------------------------------------------------------------------
RUN curl -fsSL \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# ---------------------------------------------------------------------------
# Zarf
# ---------------------------------------------------------------------------
RUN curl -fsSL \
      "https://github.com/zarf-dev/zarf/releases/download/${ZARF_VERSION}/zarf_${ZARF_VERSION}_Linux_${TARGETARCH}" \
      -o /usr/local/bin/zarf \
    && chmod +x /usr/local/bin/zarf

# ---------------------------------------------------------------------------
# Crane
# ---------------------------------------------------------------------------
# Crane (google/go-containerregistry)
# ---------------------------------------------------------------------------
RUN case "${TARGETARCH}" in \
        amd64) CRANE_ARCH="x86_64" ;; \
        arm64) CRANE_ARCH="arm64" ;; \
    esac \
    && curl -fsSL \
      "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_${CRANE_ARCH}.tar.gz" \
      -o /tmp/go-containerregistry.tar.gz \
    && tar -xzf /tmp/go-containerregistry.tar.gz \
      -C /usr/local/bin \
      crane \
    && chmod +x /usr/local/bin/crane \
    && rm -f /tmp/go-containerregistry.tar.gz

# ---------------------------------------------------------------------------
# Hubble CLI
# ---------------------------------------------------------------------------

RUN curl -L \
  "https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-${TARGETARCH}.tar.gz" \
  -o /tmp/hubble.tar.gz

RUN tar -xzf /tmp/hubble.tar.gz -C /usr/local/bin

RUN chmod +x /usr/local/bin/hubble

RUN rm /tmp/hubble.tar.gz

# OpenBao CLI for external transit-provider bootstrap.
RUN case "${TARGETARCH}" in \
      amd64) OPENBAO_SHA256="${OPENBAO_SHA256_AMD64}" ;; \
      arm64) OPENBAO_SHA256="${OPENBAO_SHA256_ARM64}" ;; \
    esac \
    && curl -fsSL "https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/openbao_${OPENBAO_VERSION}_linux_${TARGETARCH}.tar.gz" -o /tmp/openbao.tar.gz \
    && echo "${OPENBAO_SHA256}  /tmp/openbao.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/openbao.tar.gz -C /usr/local/bin bao \
    && chmod +x /usr/local/bin/bao \
    && rm /tmp/openbao.tar.gz

# ---------------------------------------------------------------------------
# Verify installed tools
# ---------------------------------------------------------------------------
RUN echo "---- Alpine ----" \
    && cat /etc/alpine-release \
    && echo "---- Go ----" \
    && go version \
    && echo "---- talosctl ----" \
    && talosctl version --client \
    && echo "---- kubectl ----" \
    && kubectl version --client \
    && echo "---- Helm ----" \
    && helm version \
    && echo "---- Zarf ----" \
    && zarf version \
    && echo "---- Crane ----" \
    && crane version \
    && echo "---- Hubble ----" \
    && hubble version \
    && echo "---- OpenBao ----" \
    && bao version \
    && echo "---- Docker ----" \
    && docker --version \
    && echo "---- Docker Compose ----" \
    && docker compose version \
    && echo "---- Docker Buildx ----" \
    && docker buildx version \
    && echo "---- curl ----" \
    && curl --version | head -n 1 \
    && echo "---- dig ----" \
    && dig -v

# --------------------------------------------------------------------------
# Docker Socket
# --------------------------------------------------------------------------
# Check docker ownership ls -ln /var/run/docker.sock
RUN addgroup -g 103 dockerhost \
    && addgroup dev dockerhost

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------
RUN mkdir -p /workspace \
    && chown -R dev:dev /workspace

WORKDIR /workspace

USER dev

CMD ["/bin/bash"]
