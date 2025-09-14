FROM debian:bookworm-slim

# Systempakete + imapfilter installieren
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      imapfilter ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*

# Standard-Entrypoint: imapfilter
ENTRYPOINT ["imapfilter"]