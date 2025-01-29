# syntax=docker/dockerfile:1.7
# Build stage for compiling the application
# Always use the latest image
# hadolint ignore=DL3007
FROM --platform=$BUILDPLATFORM cgr.dev/chainguard/wolfi-base:latest AS builder

# Build arguments for version tracking
ARG BUILDPLATFORM
ARG TARGETPLATFORM
ARG VERSION
ARG GIT_SHA

# Install build dependencies
# hadolint ignore=DL3018
RUN <<EOF
apk add --no-cache \
    build-base \
    openssl-dev \
    glibc-dev \
    posix-libc-utils \
    libffi-dev \
    python-3.13 \
    python3-dev \
    py3.13-pip \
    ccache \
    patchelf
EOF

# Create a non-root user for building
RUN --mount=type=cache,target=/var/cache/apk \
    adduser -D builder
USER builder
WORKDIR /home/builder

# Copy only necessary files
COPY --chown=builder:builder requirements.txt .
COPY --chown=builder:builder src/ src/

# Create venv and install dependencies
RUN --mount=type=cache,target=/root/.cache/pip \
    <<EOF
python -m venv /home/builder/venv
/home/builder/venv/bin/pip install --no-cache-dir -U pip setuptools wheel
/home/builder/venv/bin/pip install --no-cache-dir pyinstaller
/home/builder/venv/bin/pip install --no-cache-dir -r requirements.txt
EOF

# Build the binary with security flags
RUN --mount=type=cache,target=/root/.cache/pyinstaller \
    <<EOF
/home/builder/venv/bin/pyinstaller \
    --clean \
    --onefile \
    --strip \
    --name harbor \
    --no-upx \
    src/harbor.py
# Add version info
echo "${VERSION:-dev}" > dist/version.txt
echo "${GIT_SHA:-unknown}" > dist/gitsha.txt
EOF

# Final minimal runtime stage
# Always use the latest image
# hadolint ignore=DL3007
FROM --platform=$TARGETPLATFORM cgr.dev/chainguard/wolfi-base:latest

# Create a non-root user for running the application
RUN <<EOF
adduser -D harbor
mkdir -p /var/lib/harbor /var/log/harbor
chown -R harbor:harbor /var/lib/harbor /var/log/harbor
EOF

# Copy only the compiled binary and metadata
COPY --from=builder --chown=harbor:harbor /home/builder/dist/harbor /usr/local/bin/harbor
COPY --from=builder --chown=harbor:harbor /home/builder/dist/version.txt /var/lib/harbor/version.txt
COPY --from=builder --chown=harbor:harbor /home/builder/dist/gitsha.txt /var/lib/harbor/gitsha.txt

# Set proper permissions
RUN <<EOF
chmod 755 /usr/local/bin/harbor
chmod 644 /var/lib/harbor/version.txt /var/lib/harbor/gitsha.txt
chmod 755 /var/lib/harbor /var/log/harbor
EOF

# Use non-root user
USER harbor
WORKDIR /var/lib/harbor

# Define environment variables
ENV PYTHONUNBUFFERED=1 \
    PATH="/usr/local/bin:$PATH" \
    VERSION="${VERSION:-dev}"

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/usr/local/bin/harbor", "--version"]

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/harbor"]
