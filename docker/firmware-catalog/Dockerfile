FROM docker.io/library/node:24-alpine AS deps
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev

FROM docker.io/library/node:24-alpine AS build
WORKDIR /app
COPY package.json ./
RUN npm install
COPY . .
RUN npm run build

FROM docker.io/library/node:24-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3100 \
    HOSTNAME=0.0.0.0 \
    FIRMWARE_DATA_DIR=/data/firmwares
RUN mkdir -p /data/firmwares/files
COPY --from=build /app/public ./public
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
EXPOSE 3100
VOLUME ["/data/firmwares"]
CMD ["node", "server.js"]
