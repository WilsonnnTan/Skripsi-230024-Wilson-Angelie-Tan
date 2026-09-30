FROM node:24

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@11 --activate

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --prod --frozen-lockfile

COPY src ./src

EXPOSE 3000

USER node

CMD ["node", "src/server.js"]
