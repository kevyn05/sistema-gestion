#!/bin/bash
# Despliegue rápido del sistema

set -e

echo "🚀 Iniciando despliegue del sistema..."

# Variables
APP_DIR="/var/www/sistema-gestion"
BACKUP_DIR="/var/backups/sistema-gestion"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Crear backup antes de desplegar
echo "📦 Creando backup..."
mkdir -p ${BACKUP_DIR}/backup_${TIMESTAMP}
cp -r ${APP_DIR} ${BACKUP_DIR}/backup_${TIMESTAMP}/app
mysqldump -u sistema_user -p$(grep DB_PASSWORD ${APP_DIR}/.env | cut -d'=' -f2) \
    sistema_gestion > ${BACKUP_DIR}/backup_${TIMESTAMP}/database.sql

# Poner en modo mantenimiento
echo "🔧 Activando modo mantenimiento..."
cat > ${APP_DIR}/public/maintenance.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Sistema en Mantenimiento</title>
    <style>
        body { 
            font-family: 'Segoe UI', sans-serif; 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: white;
            text-align: center;
        }
        .container {
            background: rgba(255,255,255,0.1);
            backdrop-filter: blur(10px);
            padding: 3rem;
            border-radius: 20px;
            border: 1px solid rgba(255,255,255,0.2);
        }
        h1 { 
            font-size: 3rem; 
            margin-bottom: 1rem;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 1rem;
        }
        p { 
            font-size: 1.2rem; 
            opacity: 0.9;
            max-width: 500px;
            line-height: 1.6;
        }
        .spinner {
            border: 4px solid rgba(255,255,255,0.3);
            border-top: 4px solid white;
            border-radius: 50%;
            width: 50px;
            height: 50px;
            animation: spin 1s linear infinite;
            margin: 2rem auto;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>⚙️ <span>Sistema en Mantenimiento</span></h1>
        <p>Estamos realizando actualizaciones para mejorar el sistema. 
           Estaremos de vuelta en unos minutos.</p>
        <div class="spinner"></div>
        <p><small>${TIMESTAMP}</small></p>
    </div>
</body>
</html>
EOF

# Actualizar código
echo "🔄 Actualizando código..."
cd ${APP_DIR}
git pull origin main 2>/dev/null || echo "No hay repositorio git, continuando..."

# Instalar dependencias
echo "📦 Instalando dependencias PHP..."
composer install --no-dev --optimize-autoloader --quiet

echo "📦 Instalando dependencias Node.js..."
npm install --quiet

# Ejecutar migraciones
echo "🗃️ Ejecutando migraciones..."
php app/console migrate --force

# Construir frontend
echo "🏗️ Construyendo frontend..."
npm run build

# Limpiar caché
echo "🧹 Limpiando caché..."
rm -rf ${APP_DIR}/storage/framework/cache/*
rm -rf ${APP_DIR}/storage/framework/views/*

# Quitar modo mantenimiento
echo "✅ Finalizando despliegue..."
rm -f ${APP_DIR}/public/maintenance.html

# Reiniciar servicios
echo "🔄 Reiniciando servicios..."
systemctl reload nginx
systemctl reload php8.2-fpm

echo ""
echo "🎉 ¡Despliegue completado exitosamente!"
echo "📊 Sistema disponible en: http://localhost"
echo "⏰ Tiempo: ${TIMESTAMP}"
