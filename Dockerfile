# Dockerfile для развертывания Hayam Wiki на Fly.io
# Оптимизированная single-container архитектура

#==============================================================================
# Stage 1: API Server Build
#==============================================================================
FROM node:18-alpine AS api-builder

WORKDIR /app/api

# Устанавливаем зависимости для API
RUN npm init -y && \
    npm install --production \
        express \
        pg \
        cors \
        helmet \
        morgan \
        dotenv \
        ws \
        jsonwebtoken \
        bcrypt

# Создаем API приложение
COPY <<EOF /app/api/server.js
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const { Pool } = require('pg');
require('dotenv').config();

const app = express();

// Database connection
const pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

// Middleware
app.use(helmet({
    contentSecurityPolicy: {
        directives: {
            defaultSrc: ["'self'"],
            styleSrc: ["'self'", "'unsafe-inline'"],
            scriptSrc: ["'self'"],
            imgSrc: ["'self'", "data:", "https:"],
        },
    },
}));

app.use(cors({
    origin: process.env.CORS_ORIGINS?.split(',') || ['https://hayam-wiki.fly.dev'],
    credentials: true
}));

app.use(morgan('combined'));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true, limit: '10mb' }));

// Health check для Fly.io
app.get('/health', async (req, res) => {
    try {
        await pool.query('SELECT 1');
        res.json({ 
            status: 'OK', 
            service: 'hayam-wiki-api',
            timestamp: new Date().toISOString(),
            database: 'connected'
        });
    } catch (error) {
        res.status(500).json({ 
            status: 'ERROR', 
            service: 'hayam-wiki-api',
            error: error.message 
        });
    }
});

// API Routes
app.get('/api/v1/status', (req, res) => {
    res.json({ 
        status: 'running',
        version: '1.0.0',
        domain: process.env.SITE_DOMAIN || 'hayam-wiki.fly.dev'
    });
});

// Pages API
app.get('/api/v1/pages', async (req, res) => {
    try {
        const result = await pool.query(
            'SELECT id, title, slug, summary, view_count, created_at FROM hayam.pages WHERE status = $1 ORDER BY created_at DESC LIMIT 50',
            ['published']
        );
        res.json(result.rows);
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

app.get('/api/v1/pages/:slug', async (req, res) => {
    try {
        const result = await pool.query(
            'SELECT * FROM hayam.pages WHERE slug = $1 AND status = $2',
            [req.params.slug, 'published']
        );
        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'Page not found' });
        }
        res.json(result.rows[0]);
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// Categories API
app.get('/api/v1/categories', async (req, res) => {
    try {
        const result = await pool.query(
            'SELECT * FROM hayam.categories ORDER BY name'
        );
        res.json(result.rows);
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

const PORT = process.env.API_PORT || 3000;
const server = app.listen(PORT, '0.0.0.0', () => {
    console.log(\`Hayam Wiki API server running on port \${PORT}\`);
});

// Graceful shutdown для Fly.io
process.on('SIGTERM', () => {
    console.log('SIGTERM received, shutting down gracefully');
    server.close(() => {
        console.log('Process terminated');
        process.exit(0);
    });
});

module.exports = app;
EOF

#==============================================================================  
# Stage 2: Frontend Build
#==============================================================================
FROM node:18-alpine AS frontend-builder

WORKDIR /app/frontend

# Создаем React приложение
RUN npx create-react-app hayam-wiki --template typescript
WORKDIR /app/frontend/hayam-wiki

# Создаем компоненты для Hayam Wiki
COPY <<EOF /app/frontend/hayam-wiki/src/App.tsx
import React, { useState, useEffect } from 'react';
import './App.css';

interface Page {
  id: number;
  title: string;
  slug: string;
  summary: string;
  view_count: number;
  created_at: string;
}

interface Category {
  id: number;
  name: string;
  slug: string;
  description: string;
}

function App() {
  const [pages, setPages] = useState<Page[]>([]);
  const [categories, setCategories] = useState<Category[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetchData = async () => {
      try {
        const [pagesRes, categoriesRes] = await Promise.all([
          fetch('/api/v1/pages'),
          fetch('/api/v1/categories')
        ]);
        
        const pagesData = await pagesRes.json();
        const categoriesData = await categoriesRes.json();
        
        setPages(pagesData);
        setCategories(categoriesData);
      } catch (error) {
        console.error('Error fetching data:', error);
      } finally {
        setLoading(false);
      }
    };

    fetchData();
  }, []);

  if (loading) {
    return <div className="loading">جاري التحميل...</div>;
  }

  return (
    <div className="App">
      <header className="App-header">
        <h1>حيام ويكي - Hayam Wiki</h1>
        <p>الموسوعة العربية المفتوحة</p>
        <p>Open Arabic Encyclopedia</p>
        <div className="domain-info">
          <span>🌐 hayam-wiki.fly.dev</span>
        </div>
      </header>
      
      <main className="main-content">
        <section className="categories-section">
          <h2>التصنيفات - Categories</h2>
          <div className="categories-grid">
            {categories.map(category => (
              <div key={category.id} className="category-card">
                <h3>{category.name}</h3>
                <p>{category.description}</p>
              </div>
            ))}
          </div>
        </section>

        <section className="pages-section">
          <h2>المقالات الحديثة - Recent Articles</h2>
          <div className="pages-list">
            {pages.map(page => (
              <article key={page.id} className="page-card">
                <h3>{page.title}</h3>
                <p>{page.summary}</p>
                <div className="page-meta">
                  <span>👁️ {page.view_count}</span>
                  <span>📅 {new Date(page.created_at).toLocaleDateString('ar-SA')}</span>
                </div>
              </article>
            ))}
          </div>
        </section>
      </main>
      
      <footer className="footer">
        <p>© 2025 Hayam Wiki - Powered by Fly.io</p>
      </footer>
    </div>
  );
}

export default App;
EOF

COPY <<EOF /app/frontend/hayam-wiki/src/App.css
.App {
  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
  max-width: 1200px;
  margin: 0 auto;
  padding: 0 20px;
}

.App-header {
  background: linear-gradient(135deg, #2c3e50, #3498db);
  color: white;
  padding: 40px 20px;
  text-align: center;
  border-radius: 10px;
  margin: 20px 0;
}

.App-header h1 {
  margin: 0 0 10px 0;
  font-size: 2.5rem;
  font-weight: bold;
}

.domain-info {
  background: rgba(255,255,255,0.1);
  padding: 10px 20px;
  border-radius: 20px;
  margin-top: 20px;
  display: inline-block;
}

.loading {
  text-align: center;
  padding: 100px 20px;
  font-size: 1.5rem;
  color: #2c3e50;
}

.main-content {
  padding: 20px 0;
}

.categories-section, .pages-section {
  margin: 40px 0;
}

.categories-section h2, .pages-section h2 {
  color: #2c3e50;
  border-bottom: 3px solid #3498db;
  padding-bottom: 10px;
  margin-bottom: 30px;
}

.categories-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  gap: 20px;
  margin-bottom: 40px;
}

.category-card {
  background: #f8f9fa;
  border: 1px solid #e9ecef;
  border-radius: 10px;
  padding: 20px;
  transition: transform 0.2s, box-shadow 0.2s;
}

.category-card:hover {
  transform: translateY(-2px);
  box-shadow: 0 4px 15px rgba(0,0,0,0.1);
}

.category-card h3 {
  color: #2c3e50;
  margin: 0 0 10px 0;
}

.pages-list {
  display: grid;
  gap: 20px;
}

.page-card {
  background: white;
  border: 1px solid #e9ecef;
  border-radius: 10px;
  padding: 25px;
  box-shadow: 0 2px 10px rgba(0,0,0,0.05);
  transition: transform 0.2s, box-shadow 0.2s;
}

.page-card:hover {
  transform: translateY(-2px);
  box-shadow: 0 4px 20px rgba(0,0,0,0.1);
}

.page-card h3 {
  color: #2c3e50;
  margin: 0 0 15px 0;
  font-size: 1.4rem;
}

.page-meta {
  display: flex;
  gap: 20px;
  margin-top: 15px;
  color: #6c757d;
  font-size: 0.9rem;
}

.footer {
  background: #2c3e50;
  color: white;
  text-align: center;
  padding: 30px 20px;
  margin-top: 60px;
  border-radius: 10px;
}

/* RTL Support */
[dir="rtl"] {
  text-align: right;
}

@media (max-width: 768px) {
  .App-header h1 {
    font-size: 2rem;
  }
  
  .categories-grid {
    grid-template-columns: 1fr;
  }
  
  .page-meta {
    flex-direction: column;
    gap: 10px;
  }
}
EOF

# Обновляем package.json
RUN npm install --save-dev @types/react @types/react-dom

# Собираем React приложение  
RUN npm run build

#==============================================================================
# Stage 3: Production (Nginx + Node.js)
#==============================================================================
FROM nginx:alpine

# Устанавливаем Node.js в Nginx контейнер
RUN apk add --no-cache nodejs npm curl supervisor

# Создаем директории
RUN mkdir -p /app/api /app/logs /etc/supervisor/conf.d

# Копируем API сервер
COPY --from=api-builder /app/api /app/api

# Копируем собранный frontend
COPY --from=frontend-builder /app/frontend/hayam-wiki/build /usr/share/nginx/html

# Конфигурация Nginx для Fly.io
COPY <<EOF /etc/nginx/nginx.conf
user nginx;
worker_processes 1;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/atom+xml image/svg+xml;

    upstream api {
        server 127.0.0.1:3000;
    }

    server {
        listen \${PORT:-8080};
        server_name hayam-wiki.fly.dev _;
        
        root /usr/share/nginx/html;
        index index.html index.htm;

        # Security headers
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;

        # API proxy
        location /api/ {
            proxy_pass http://api/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host \$host;
        }

        # Health check
        location /health {
            proxy_pass http://api/health;
            access_log off;
        }

        # Static files
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }

        # SPA routing
        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

# Supervisor конфигурация для запуска Nginx + Node.js
COPY <<EOF /etc/supervisor/conf.d/supervisord.conf
[supervisord]
nodaemon=true
user=root
logfile=/app/logs/supervisord.log
pidfile=/var/run/supervisord.pid

[program:nginx]
command=nginx -g "daemon off;"
stdout_logfile=/app/logs/nginx-stdout.log
stderr_logfile=/app/logs/nginx-stderr.log
autorestart=true
priority=1

[program:api]
command=node /app/api/server.js
directory=/app/api
stdout_logfile=/app/logs/api-stdout.log
stderr_logfile=/app/logs/api-stderr.log
autorestart=true
priority=2
environment=NODE_ENV=production,PORT=3000
EOF

# Entrypoint скрипт для Fly.io
COPY <<EOF /app/fly-entrypoint.sh
#!/bin/sh

# Заменяем переменные в nginx.conf
envsubst '\$PORT' < /etc/nginx/nginx.conf > /tmp/nginx.conf
cp /tmp/nginx.conf /etc/nginx/nginx.conf

# Запускаем supervisor
exec supervisord -c /etc/supervisor/conf.d/supervisord.conf
EOF

RUN chmod +x /app/fly-entrypoint.sh

# Переменные окружения
ENV NODE_ENV=production
ENV PORT=8080
ENV API_PORT=3000
ENV SITE_DOMAIN=hayam-wiki.fly.dev
ENV CORS_ORIGINS=https://hayam-wiki.fly.dev

# Создаем пользователя для безопасности
RUN addgroup -g 1001 -S appuser && \
    adduser -S appuser -u 1001 -G appuser

# Устанавливаем права
RUN chown -R appuser:appuser /app /usr/share/nginx/html /var/log/nginx /var/cache/nginx /var/run

# Health check для Fly.io
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:$PORT/health || exit 1

# Метаданные
LABEL maintainer="omar@hayamwiki.org"
LABEL version="1.0.0-fly"
LABEL description="Hayam Wiki - Fly.io Deployment"
LABEL fly.app="hayam-wiki"

EXPOSE 8080

USER appuser

CMD ["/app/fly-entrypoint.sh"]