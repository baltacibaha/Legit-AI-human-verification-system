# ── Stage 1: dependency builder ──────────────────────────────
FROM node:20-alpine AS deps

RUN apk add --no-cache python3 make g++ libc-dev linux-headers

WORKDIR /build
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ── Stage 2: production image ─────────────────────────────────
FROM node:20-alpine AS production

RUN apk add --no-cache dumb-init wget

RUN addgroup --system --gid 1001 legit \
 && adduser  --system --uid 1001 --ingroup legit --no-create-home --disabled-password legit

WORKDIR /app

COPY --from=deps --chown=legit:legit /build/node_modules ./node_modules
COPY --chown=legit:legit index.js        ./
COPY --chown=legit:legit ipfsService.js  ./
COPY --chown=legit:legit easService.js   ./
COPY --chown=legit:legit scripts/        ./scripts/

RUN mkdir -p /var/log/legit && chown legit:legit /var/log/legit

USER legit

EXPOSE 3001

HEALTHCHECK \
    --interval=30s \
    --timeout=5s   \
    --start-period=20s \
    --retries=3    \
    CMD wget -qO- http://127.0.0.1:3001/health || exit 1

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["node", "index.js"]
