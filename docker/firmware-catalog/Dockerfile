FROM docker.io/library/node:24-alpine AS build
WORKDIR /app
COPY docker/firmware-catalog/package.json ./
RUN npm install
COPY docker/firmware-catalog/ ./
RUN npm run build

FROM docker.io/library/node:24-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3100 \
    HOSTNAME=0.0.0.0 \
    FIRMWARE_DATA_DIR=/data/firmwares \
    FIRMWARE_SEED_DIR=/opt/firmware-seed
RUN mkdir -p /data/firmwares/files /opt/firmware-seed
# Seed the official Virtual ECU binaries so edge can download them for OTA.
COPY bin/ecu/linux-amd64/virtual-thermal-ecu-sim-1.0.0 \
     /opt/firmware-seed/virtual-thermal-ecu-sim-1.0.0
COPY bin/ecu/linux-amd64/virtual-thermal-ecu-sim-1.1.0 \
     /opt/firmware-seed/virtual-thermal-ecu-sim-1.1.0
COPY --from=build /app/public ./public
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY docker/firmware-catalog/seed-and-start.sh /usr/local/bin/seed-and-start.sh
RUN chmod 755 /usr/local/bin/seed-and-start.sh \
              /opt/firmware-seed/virtual-thermal-ecu-sim-1.0.0 \
              /opt/firmware-seed/virtual-thermal-ecu-sim-1.1.0
EXPOSE 3100
VOLUME ["/data/firmwares"]
CMD ["/usr/local/bin/seed-and-start.sh"]
