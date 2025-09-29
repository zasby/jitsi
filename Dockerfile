# Dockerfile для MiroTalk
FROM node:18-alpine

# Установка необходимых пакетов
RUN apk add --no-cache \
    git \
    curl \
    bash \
    && rm -rf /var/cache/apk/*

# Создание рабочей директории
WORKDIR /app

# Копирование файлов package.json
COPY package*.json ./

# Установка зависимостей
RUN npm ci --only=production && npm cache clean --force

# Копирование исходного кода
COPY . .

# Создание пользователя для безопасности
RUN addgroup -g 1001 -S nodejs && \
    adduser -S mirotalk -u 1001

# Создание необходимых директорий
RUN mkdir -p /app/logs /app/data /app/recordings && \
    chown -R mirotalk:nodejs /app

# Переключение на пользователя mirotalk
USER mirotalk

# Открытие порта
EXPOSE 3000

# Проверка здоровья
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

# Запуск приложения
CMD ["npm", "start"]

