FROM node:20-alpine

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install --omit=dev

COPY src ./src

# STORE_PATH defaults to ./data/store.json; mount a volume at /data and set
# STORE_PATH=/data/store.json in production (see fly.toml / docker-compose.yml).
RUN mkdir -p /data

ENV STORE_PATH=/data/store.json
VOLUME ["/data"]

CMD ["node", "src/index.js"]
