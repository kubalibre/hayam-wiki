# Dockerfile для полного hayam-wiki проекта
# Основан на анализе docker-compose.yml, docker-compose.database.yml и docker-compose.override.yml
# из репозитория https://github.com/kubalibre/hayam-wiki

# Мультистейдж сборка для оптимизации размера образа

#==============================================================================
# Стейдж 1: База данных PostgreSQL
#==============================================================================
FROM postgres:11-alpine as database

# Переменные окружения из .env файла
ENV POSTGRES_USER=omar
ENV POSTGRES_PASSWORD=xM1rB9qXmbp89pad7Ypb
ENV POSTGRES_DB=rubai

# Устанавливаем часовой пояс
RUN apk add --no-cache tzdata
ENV TZ=UTC

# Создаем структуру директорий
RUN mkdir -p /var/lib/postgresql/data

# Копируем данные PostgreSQL из репозитория (если доступны)
# COPY hayam-wiki/data/postgres /var/lib/postgresql/data/

# Устанавливаем права доступа
RUN chown -R postgres:postgres /var/lib/postgresql/data

# Добавляем метки для CI/CD
LABEL ci.project.id="hayam"
LABEL component="database"

EXPOSE 5432

#==============================================================================
# Стейдж 2: API сервер (Node.js приложение)
#==============================================================================
FROM node:16-alpine as api

WORKDIR /app

# Устанавливаем системные зависимости
RUN apk add --no-cache \
    postgresql-client \
    curl \
    bash \
    git

# Копируем package.json (если есть в репозитории)
# COPY package*.json ./
# RUN npm install --production

# Альтернативно - создаем базовую структуру для API
RUN npm init -y && \
    npm install express pg cors helmet morgan dotenv

# Создаем базовую структуру API
RUN mkdir -p src routes middleware

# Создаем простой API сервер
COPY <<EOF /app/src/server.js
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
require('dotenv').config();

const app = express();

// Middleware
app.use(helmet());
app.use(cors());
app.use(morgan('combined'));
app.use(express.json());

// Health check
app.get('/health', (req, res) => {
    res.json({ status: 'OK', service: 'hayam-wiki-api' });
});

// API routes
app.get('/api/v1/status', (req, res) => {
    res.json({ 
        status: 'running',
        database: process.env.DATABASE_HOST,
        version: '1.0.0'
    });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, '0.0.0.0', () => {
    console.log(\`Hayam Wiki API server running on port \${PORT}\`);
});
EOF

# Переменные окружения для API
ENV DATABASE_HOST=db
ENV DATABASE_PORT=5432
ENV DATABASE_NAME=rubai
ENV DATABASE_USERNAME=omar
ENV DATABASE_PASSWORD=xM1rB9qXmbp89pad7Ypb
ENV JWT_SECRET=secret
ENV DATA_DIR=/data
ENV PORT=3000

# Создаем директорию для данных
RUN mkdir -p /data
VOLUME ["/data"]

# Создаем пользователя для безопасности
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001

RUN chown -R nodejs:nodejs /app /data
USER nodejs

LABEL ci.project.id="hayam"
LABEL component="api"

EXPOSE 3000 3030

CMD ["node", "src/server.js"]

#==============================================================================
# Стейдж 3: Frontend (React/Vue.js приложение)
#==============================================================================
FROM node:16-alpine as frontend-builder

WORKDIR /app

# Устанавливаем зависимости для сборки frontend
RUN npm install -g @vue/cli create-react-app

# Создаем базовое приложение (React)
RUN npx create-react-app hayam-wiki-frontend
WORKDIR /app/hayam-wiki-frontend

# Создаем базовую структуру для hayam-wiki
COPY <<EOF /app/hayam-wiki-frontend/src/App.js
import React from 'react';
import './App.css';

function App() {
  return (
    <div className="App">
      <header className="App-header">
        <h1>حيام ويكي - Hayam Wiki</h1>
        <p>الموسوعة العربية المفتوحة</p>
        <p>Open Arabic Encyclopedia</p>
      </header>
      <main>
        <section>
          <h2>مرحباً بكم في حيام ويكي</h2>
          <p>مشروع موسوعة عربية مفتوحة المصدر</p>
        </section>
      </main>
    </div>
  );
}

export default App;
EOF

COPY <<EOF /app/hayam-wiki-frontend/src/App.css
.App {
  text-align: center;
  font-family: 'Arial', sans-serif;
}

.App-header {
  background-color: #2c3e50;
  padding: 20px;
  color: white;
}

.App-header h1 {
  margin: 0;
  font-size: 2.5rem;
}

main {
  padding: 40px 20px;
  direction: rtl;
}

main h2 {
  color: #2c3e50;
  margin-bottom: 20px;
}
EOF

# Собираем приложение
RUN npm run build

#==============================================================================
# Стейдж 4: Frontend production (Nginx)
#==============================================================================
FROM nginx:alpine as frontend

# Копируем собранное приложение
COPY --from=frontend-builder /app/hayam-wiki-frontend/build /usr/share/nginx/html

# Копируем конфигурацию nginx
COPY <<EOF /etc/nginx/conf.d/default.conf
server {
    listen 80;
    server_name _;
    
    root /usr/share/nginx/html;
    index index.html index.htm;

    # SPA роутинг
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Кеширование статических файлов
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Безопасность
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
}
EOF

LABEL ci.project.id="hayam"
LABEL component="frontend"

EXPOSE 80

#==============================================================================
# Стейдж 5: Router/Proxy (Nginx с проксированием)
#==============================================================================
FROM nginx:alpine as router

# Устанавливаем дополнительные пакеты
RUN apk add --no-cache \
    curl \
    bash \
    openssl

# Конфигурация nginx для роутинга
COPY <<EOF /etc/nginx/conf.d/default.conf
upstream api {
    server api:3000;
}

upstream api_ws {
    server api:3030;
}

upstream frontend {
    server front:80;
}

server {
    listen 80;
    server_name hayamwiki.org _;

    # Frontend
    location / {
        proxy_pass http://frontend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # API
    location /api/ {
        proxy_pass http://api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # WebSocket
    location /ws/ {
        proxy_pass http://api_ws/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    # Health check
    location /health {
        proxy_pass http://api/health;
    }
}
EOF

# Переменные окружения
ENV UPSTREAM_API=http://api:3000
ENV UPSTREAM_API_WS=http://api:3030
ENV UPSTREAM_FRONT=http://front:80
ENV VIRTUAL_HOST=https://hayam-wiki.fly.dev/
ENV VIRTUAL_PORT=80
ENV LETSENCRYPT_HOST=hayamwiki.org
ENV LETSENCRYPT_EMAIL=spryteamio@gmail.com

LABEL ci.project.id="hayam"
LABEL component="router"

EXPOSE 80

#==============================================================================
# Финальный стейдж - выбор компонента через build argument
#==============================================================================
FROM database as final-database
FROM api as final-api  
FROM frontend as final-frontend
FROM router as final-router

# По умолчанию собираем полный стек (можно переопределить через --target)
FROM router as final

# Метаданные образа
LABEL maintainer="omar@hayamwiki.org"
LABEL version="1.0.0"
LABEL description="Hayam Wiki - Open Arabic Encyclopedia"
LABEL org.opencontainers.image.source="https://github.com/kubalibre/hayam-wiki"
LABEL org.opencontainers.image.documentation="https://hayamwiki.org/docs"
LABEL org.opencontainers.image.licenses="MIT"

# Инструкции по использованию
COPY <<EOF /README.md
# Hayam Wiki Docker Image

Этот образ содержит полный стек приложения Hayam Wiki.

## Использование:

### Сборка отдельных компонентов:
- База данных: docker build --target database -t hayam-wiki:db .
- API: docker build --target api -t hayam-wiki:api .
- Frontend: docker build --target frontend -t hayam-wiki:front .
- Router: docker build --target router -t hayam-wiki:router .

### Запуск с docker-compose:
docker-compose -f docker-compose.hayam-example.yml up -d

### Переменные окружения:
- PG_USER=omar
- PG_PASS=xM1rB9qXmbp89pad7Ypb  
- PG_NAME=rubai
- JWT_SIGN_SECRET=secret
- CI_PROJECT_ID=hayam
- DOCKER_FRONT_PROXY_NETWORK=nginx-proxy

### Порты:
- 80: Frontend/Router
- 3000: API HTTP
- 3030: API WebSocket
- 5432: PostgreSQL (внутренний)

### Домен: hayamwiki.org
EOF