# GitHub Actions runner on Kubernetes
# Uses the official actions/runner image as base, adds entrypoint script
# that fetches ephemeral registration token via GH_TOKEN from ESO-managed Secret.
FROM ghcr.io/actions/runner:latest

# CAA certs required so runners can reach GitHub API from behind corporate proxies
USER root
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Entrypoint script handles ephemeral runner token provisioning using GH_TOKEN
# from the ESO-managed Secret mounted at /secrets/runner (via volumeMount).
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER runner
ENTRYPOINT ["/entrypoint.sh"]