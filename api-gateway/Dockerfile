FROM node:20-alpine

WORKDIR /app

# Install dependencies first so they're cached unless package.json changes.
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

COPY index.js ./

# Run as non-root.
RUN addgroup -S app && adduser -S app -G app
USER app

EXPOSE 8080

CMD ["node", "index.js"]
