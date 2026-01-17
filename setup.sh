#!/bin/bash
# Sistema de Gestión Empresarial - Instalación Completa
# Debian 12 / Ubuntu 22.04+

set -e

echo "==============================================="
echo "  INSTALACIÓN SISTEMA DE GESTIÓN EMPRESARIAL  "
echo "==============================================="

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Función para imprimir con colores
print_status() {
    echo -e "${BLUE}[*]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# Verificar que somos root
if [ "$EUID" -ne 0 ]; then
    print_error "Este script debe ejecutarse como root"
    exit 1
fi

# Configuración
DOMAIN="sistema.local"
DB_NAME="sistema_gestion"
DB_USER="sistema_user"
DB_PASS=$(openssl rand -base64 16)
APP_DIR="/var/www/sistema-gestion"
LOG_DIR="/var/log/sistema-gestion"
BACKUP_DIR="/var/backups/sistema-gestion"

print_status "Actualizando sistema..."
apt update && apt upgrade -y

print_status "Instalando dependencias del sistema..."
apt install -y nginx mariadb-server php8.2-fpm php8.2-mysql php8.2-curl \
    php8.2-gd php8.2-mbstring php8.2-xml php8.2-zip php8.2-bcmath \
    php8.2-intl php8.2-soap php8.2-imagick php8.2-redis \
    redis-server composer nodejs npm git curl wget unzip \
    ufw certbot python3-certbot-nginx

print_status "Configurando firewall..."
ufw --force enable
ufw allow ssh
ufw allow 'Nginx Full'
ufw allow 3000  # Para desarrollo
ufw reload

print_status "Configurando MariaDB..."
systemctl start mariadb
systemctl enable mariadb

# Configuración segura de MariaDB
mysql_secure_installation <<EOF

y
${DB_PASS}
${DB_PASS}
y
y
y
y
EOF

print_status "Creando base de datos y usuario..."
mysql -u root -p${DB_PASS} <<MYSQL_SCRIPT
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

print_status "Creando directorios del sistema..."
mkdir -p ${APP_DIR}
mkdir -p ${LOG_DIR}
mkdir -p ${BACKUP_DIR}
mkdir -p ${APP_DIR}/{public,app,storage,config,logs,temp}

print_status "Creando estructura de la aplicación..."
cat > ${APP_DIR}/index.php << 'EOF'
<?php
/**
 * Punto de entrada principal del sistema
 */
require_once __DIR__ . '/app/bootstrap.php';

use Sistema\Core\Application;

$app = new Application();
$app->run();
EOF

# Crear archivo de configuración PHP
cat > /etc/php/8.2/fpm/conf.d/sistema.ini << EOF
upload_max_filesize = 50M
post_max_size = 50M
max_execution_time = 300
max_input_time = 300
memory_limit = 256M
date.timezone = America/Caracas
error_log = ${LOG_DIR}/php-error.log
EOF

print_status "Configurando Nginx..."
cat > /etc/nginx/sites-available/sistema-gestion << EOF
server {
    listen 80;
    server_name ${DOMAIN} localhost 127.0.0.1;
    root ${APP_DIR}/public;
    index index.php index.html index.htm;

    access_log ${LOG_DIR}/nginx-access.log;
    error_log ${LOG_DIR}/nginx-error.log;

    client_max_body_size 50M;
    client_body_timeout 300s;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        log_not_found off;
    }

    # Headers de seguridad
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self' https: data: 'unsafe-inline' 'unsafe-eval';" always;
}
EOF

ln -sf /etc/nginx/sites-available/sistema-gestion /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

print_status "Configurando PHP-FPM..."
cat > /etc/php/8.2/fpm/pool.d/sistema.conf << EOF
[sistema]
user = www-data
group = www-data
listen = /var/run/php/php8.2-fpm-sistema.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 25
pm.start_servers = 5
pm.min_spare_servers = 3
pm.max_spare_servers = 10

pm.max_requests = 500
request_terminate_timeout = 300
request_slowlog_timeout = 10
slowlog = ${LOG_DIR}/php-slow.log

php_admin_value[error_log] = ${LOG_DIR}/php-fpm-error.log
php_admin_flag[log_errors] = on
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[upload_max_filesize] = 50M
php_admin_value[post_max_size] = 50M
EOF

print_status "Configurando permisos..."
chown -R www-data:www-data ${APP_DIR}
chown -R www-data:www-data ${LOG_DIR}
chmod -R 755 ${APP_DIR}
chmod -R 775 ${APP_DIR}/storage
chmod -R 775 ${LOG_DIR}

print_status "Creando script de backup..."
cat > /usr/local/bin/backup-sistema << EOF
#!/bin/bash
BACKUP_FILE="${BACKUP_DIR}/sistema-\$(date +%Y%m%d-%H%M%S).sql"
mysqldump -u ${DB_USER} -p${DB_PASS} ${DB_NAME} > \${BACKUP_FILE}
tar -czf "\${BACKUP_FILE}.tar.gz" ${APP_DIR} --exclude="node_modules" --exclude="vendor"
find ${BACKUP_DIR} -type f -mtime +7 -delete
echo "Backup completado: \${BACKUP_FILE}.tar.gz"
EOF
chmod +x /usr/local/bin/backup-sistema

print_status "Creando servicio systemd..."
cat > /etc/systemd/system/sistema-gestion.service << EOF
[Unit]
Description=Sistema de Gestión Empresarial
After=network.target mariadb.service redis-server.service

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/php ${APP_DIR}/app/console server:start
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

print_status "Creando tarea programada de mantenimiento..."
cat > /etc/cron.d/sistema-gestion << EOF
# Backup diario a las 2 AM
0 2 * * * root /usr/local/bin/backup-sistema

# Limpieza de logs cada domingo
0 3 * * 0 root find ${LOG_DIR} -type f -name "*.log" -mtime +30 -delete

# Monitoreo de espacio
0 4 * * * root df -h | grep -E '(100|9[0-9])%' && echo "Espacio bajo en $(hostname)" | mail -s "Alerta Sistema" admin@localhost
EOF

print_status "Reiniciando servicios..."
systemctl daemon-reload
systemctl restart nginx php8.2-fpm mariadb redis-server
systemctl enable nginx php8.2-fpm mariadb redis-server

print_status "Creando archivo .env..."
cat > ${APP_DIR}/.env << EOF
# Configuración del Sistema
APP_NAME="Sistema de Gestión Empresarial"
APP_ENV=production
APP_DEBUG=false
APP_URL=http://${DOMAIN}

# Base de datos
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}

# Sesión y Cache
SESSION_DRIVER=redis
CACHE_DRIVER=redis
QUEUE_CONNECTION=redis

# Moneda y IVA
DEFAULT_CURRENCY=USD
SUPPORTED_CURRENCIES=USD,VES,EUR
IVA_PERCENTAGE=16

# Seguridad
JWT_SECRET=$(openssl rand -base64 32)
APP_KEY=$(openssl rand -base64 32)

# Archivos
UPLOAD_MAX_SIZE=50
ALLOWED_EXTENSIONS=pdf,jpg,jpeg,png,doc,docx,xls,xlsx

# Email (configurar según necesidad)
MAIL_DRIVER=smtp
MAIL_HOST=smtp.gmail.com
MAIL_PORT=587
MAIL_USERNAME=
MAIL_PASSWORD=
MAIL_ENCRYPTION=tls
EOF

print_status "Instalando dependencias Node.js para frontend..."
cd ${APP_DIR}
cat > package.json << 'EOF'
{
  "name": "sistema-gestion",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "vue": "^3.3.4",
    "vue-router": "^4.2.4",
    "pinia": "^2.1.6",
    "axios": "^1.5.0",
    "chart.js": "^4.4.0",
    "vue-chartjs": "^5.2.0",
    "primevue": "^3.39.0",
    "primeicons": "^6.0.1",
    "lodash": "^4.17.21",
    "dayjs": "^1.11.9",
    "decimal.js": "^10.4.3"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^4.3.4",
    "vite": "^4.4.9",
    "sass": "^1.67.0",
    "autoprefixer": "^10.4.15",
    "postcss": "^8.4.29",
    "tailwindcss": "^3.3.3"
  }
}
EOF

npm install

print_status "Creando estructura de la aplicación PHP..."
mkdir -p ${APP_DIR}/app/{Core,Controllers,Models,Services,Repositories,DTOs,Enums,Exceptions,Middleware,Helpers}
mkdir -p ${APP_DIR}/app/Models/{Company,Branch,Sale,AccountMovement,Expense,Invoice,AuditLog,SystemLog,User}
mkdir -p ${APP_DIR}/resources/{views,lang,assets/{js,css,images}}
mkdir -p ${APP_DIR}/routes
mkdir -p ${APP_DIR}/database/{migrations,seeders}
mkdir -p ${APP_DIR}/storage/{app,framework,logs}
mkdir -p ${APP_DIR}/tests/{Unit,Feature}

print_success "==============================================="
print_success "  INSTALACIÓN COMPLETADA EXITOSAMENTE"
print_success "==============================================="
echo ""
echo "📊 DATOS DE ACCESO:"
echo "   URL: http://${DOMAIN} o http://localhost"
echo "   Directorio: ${APP_DIR}"
echo "   Base de datos: ${DB_NAME}"
echo "   Usuario BD: ${DB_USER}"
echo "   Contraseña BD: ${DB_PASS}"
echo ""
echo "🔧 PRÓXIMOS PASOS:"
echo "   1. cd ${APP_DIR}"
echo "   2. Ejecutar: ./install-app.sh"
echo "   3. Configurar certificado SSL: certbot --nginx -d ${DOMAIN}"
echo ""
echo "📝 LOGS DEL SISTEMA:"
echo "   Nginx: ${LOG_DIR}/nginx-*.log"
echo "   PHP: ${LOG_DIR}/php-*.log"
echo "   Aplicación: ${LOG_DIR}/app.log"
echo ""
print_warning "Guarde la contraseña de la base de datos en un lugar seguro!"
