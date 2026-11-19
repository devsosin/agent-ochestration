# Docker API proxy sidecar (compose service `docker`). Build with `bin/proj build` (tag agent-hub:dockerproxy).
FROM python:3.12-alpine
COPY server.py /usr/local/bin/dockerproxy
CMD ["python3", "-u", "/usr/local/bin/dockerproxy"]
