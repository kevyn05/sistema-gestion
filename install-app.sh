#!/bin/bash
# Instalación de la aplicación de gestión empresarial

set -e

APP_DIR="/var/www/sistema-gestion"
cd ${APP_DIR}

echo "Instalando aplicación PHP..."

# 1. Crear composer.json
cat > composer.json << 'EOF'
{
    "name": "sistema/gestion",
    "description": "Sistema de Gestión Empresarial",
    "type": "project",
    "require": {
        "php": "^8.2",
        "ext-json": "*",
        "ext-mbstring": "*",
        "ext-pdo": "*",
        "vlucas/phpdotenv": "^5.5",
        "firebase/php-jwt": "^6.8",
        "monolog/monolog": "^3.4",
        "illuminate/database": "^10.0",
        "illuminate/events": "^10.0",
        "illuminate/pagination": "^10.0",
        "nesbot/carbon": "^2.67",
        "respect/validation": "^2.2",
        "phpmailer/phpmailer": "^6.8",
        "league/flysystem": "^3.15",
        "mpdf/mpdf": "^8.1",
        "phpoffice/phpspreadsheet": "^1.29"
    },
    "autoload": {
        "psr-4": {
            "Sistema\\": "app/"
        }
    },
    "config": {
        "optimize-autoloader": true,
        "preferred-install": "dist",
        "sort-packages": true
    },
    "minimum-stability": "stable",
    "prefer-stable": true
}
EOF

# 2. Instalar dependencias PHP
composer install --no-dev --optimize-autoloader

# 3. Crear bootstrap.php
cat > app/bootstrap.php << 'EOF'
<?php
/**
 * Bootstrap de la aplicación
 */

// Registrar autoloader de Composer
require_once __DIR__ . '/../vendor/autoload.php';

// Cargar variables de entorno
if (file_exists(__DIR__ . '/../.env')) {
    $dotenv = Dotenv\Dotenv::createImmutable(__DIR__ . '/../');
    $dotenv->load();
}

// Configurar manejo de errores
error_reporting(E_ALL);
ini_set('display_errors', $_ENV['APP_DEBUG'] === 'true' ? '1' : '0');
ini_set('log_errors', '1');
ini_set('error_log', __DIR__ . '/../storage/logs/php-errors.log');

// Configurar zona horaria
date_default_timezone_set($_ENV['APP_TIMEZONE'] ?? 'America/Caracas');

// Definir constantes
define('APP_ROOT', dirname(__DIR__));
define('APP_STORAGE', APP_ROOT . '/storage');
define('APP_PUBLIC', APP_ROOT . '/public');
define('APP_VIEWS', APP_ROOT . '/resources/views');
define('APP_CACHE', APP_STORAGE . '/framework/cache');

// Inicializar sesión
if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

// Cargar helpers
require_once __DIR__ . '/Helpers/functions.php';

// Registrar shutdown function
register_shutdown_function(function() {
    $error = error_get_last();
    if ($error && in_array($error['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR])) {
        http_response_code(500);
        echo json_encode([
            'error' => 'Error interno del servidor',
            'message' => $_ENV['APP_DEBUG'] === 'true' ? $error['message'] : 'Contacte al administrador'
        ]);
    }
});
EOF

# 4. Crear clase Application principal
cat > app/Core/Application.php << 'EOF'
<?php

namespace Sistema\Core;

use PDO;
use PDOException;
use Monolog\Logger;
use Monolog\Handler\StreamHandler;
use Monolog\Handler\RotatingFileHandler;
use Sistema\Core\Database\DatabaseManager;
use Sistema\Core\Auth\AuthManager;
use Sistema\Core\Session\SessionManager;
use Sistema\Core\Cache\CacheManager;
use Sistema\Core\Mail\MailManager;

class Application
{
    private static $instance;
    private $config;
    private $db;
    private $auth;
    private $session;
    private $cache;
    private $mail;
    private $logger;
    private $router;

    public function __construct()
    {
        $this->loadConfig();
        $this->initLogger();
        $this->initDatabase();
        $this->initAuth();
        $this->initSession();
        $this->initCache();
        $this->initMail();
        $this->initRouter();
        
        self::$instance = $this;
    }

    public static function getInstance(): self
    {
        if (self::$instance === null) {
            self::$instance = new self();
        }
        return self::$instance;
    }

    private function loadConfig(): void
    {
        $this->config = [
            'app' => [
                'name' => $_ENV['APP_NAME'],
                'env' => $_ENV['APP_ENV'],
                'debug' => $_ENV['APP_DEBUG'] === 'true',
                'url' => $_ENV['APP_URL'],
                'timezone' => $_ENV['APP_TIMEZONE'] ?? 'America/Caracas',
                'locale' => $_ENV['APP_LOCALE'] ?? 'es',
                'currencies' => explode(',', $_ENV['SUPPORTED_CURRENCIES']),
                'default_currency' => $_ENV['DEFAULT_CURRENCY'],
                'iva_percentage' => floatval($_ENV['IVA_PERCENTAGE']),
            ],
            'database' => [
                'driver' => $_ENV['DB_CONNECTION'],
                'host' => $_ENV['DB_HOST'],
                'port' => $_ENV['DB_PORT'],
                'database' => $_ENV['DB_DATABASE'],
                'username' => $_ENV['DB_USERNAME'],
                'password' => $_ENV['DB_PASSWORD'],
                'charset' => 'utf8mb4',
                'collation' => 'utf8mb4_unicode_ci',
            ],
            'session' => [
                'driver' => $_ENV['SESSION_DRIVER'],
                'lifetime' => $_ENV['SESSION_LIFETIME'] ?? 120,
                'encrypt' => $_ENV['SESSION_ENCRYPT'] === 'true',
            ],
            'cache' => [
                'driver' => $_ENV['CACHE_DRIVER'],
                'prefix' => $_ENV['CACHE_PREFIX'] ?? 'sistema_',
            ],
            'mail' => [
                'driver' => $_ENV['MAIL_DRIVER'],
                'host' => $_ENV['MAIL_HOST'],
                'port' => $_ENV['MAIL_PORT'],
                'username' => $_ENV['MAIL_USERNAME'],
                'password' => $_ENV['MAIL_PASSWORD'],
                'encryption' => $_ENV['MAIL_ENCRYPTION'],
                'from' => [
                    'address' => $_ENV['MAIL_FROM_ADDRESS'],
                    'name' => $_ENV['MAIL_FROM_NAME'],
                ],
            ],
            'security' => [
                'jwt_secret' => $_ENV['JWT_SECRET'],
                'app_key' => $_ENV['APP_KEY'],
                'bcrypt_rounds' => $_ENV['BCRYPT_ROUNDS'] ?? 10,
            ],
            'files' => [
                'upload_max_size' => intval($_ENV['UPLOAD_MAX_SIZE']),
                'allowed_extensions' => explode(',', $_ENV['ALLOWED_EXTENSIONS']),
            ],
        ];
    }

    private function initLogger(): void
    {
        $this->logger = new Logger('sistema');
        
        // Handler para archivo diario
        $this->logger->pushHandler(
            new RotatingFileHandler(
                APP_STORAGE . '/logs/app.log',
                30, // Mantener 30 días
                Logger::DEBUG
            )
        );
        
        // Handler para errores críticos
        $this->logger->pushHandler(
            new StreamHandler(
                APP_STORAGE . '/logs/error.log',
                Logger::ERROR
            )
        );
    }

    private function initDatabase(): void
    {
        try {
            $config = $this->config['database'];
            $dsn = "mysql:host={$config['host']};port={$config['port']};dbname={$config['database']};charset={$config['charset']}";
            
            $this->db = new PDO($dsn, $config['username'], $config['password'], [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES => false,
                PDO::MYSQL_ATTR_INIT_COMMAND => "SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci",
            ]);
            
            $this->logger->info('Conexión a base de datos establecida');
        } catch (PDOException $e) {
            $this->logger->error('Error de conexión a base de datos: ' . $e->getMessage());
            throw $e;
        }
    }

    private function initAuth(): void
    {
        $this->auth = new AuthManager($this->config['security']);
    }

    private function initSession(): void
    {
        $this->session = new SessionManager($this->config['session']);
    }

    private function initCache(): void
    {
        $this->cache = new CacheManager($this->config['cache']);
    }

    private function initMail(): void
    {
        $this->mail = new MailManager($this->config['mail']);
    }

    private function initRouter(): void
    {
        $this->router = new Router();
        
        // Cargar rutas
        $routesFile = APP_ROOT . '/routes/web.php';
        if (file_exists($routesFile)) {
            require $routesFile;
        }
    }

    public function run(): void
    {
        try {
            $this->router->dispatch();
        } catch (\Exception $e) {
            $this->handleException($e);
        }
    }

    public function getConfig(string $key = null)
    {
        if ($key === null) {
            return $this->config;
        }
        
        $keys = explode('.', $key);
        $value = $this->config;
        
        foreach ($keys as $k) {
            if (isset($value[$k])) {
                $value = $value[$k];
            } else {
                return null;
            }
        }
        
        return $value;
    }

    public function getDatabase(): PDO
    {
        return $this->db;
    }

    public function getAuth(): AuthManager
    {
        return $this->auth;
    }

    public function getSession(): SessionManager
    {
        return $this->session;
    }

    public function getCache(): CacheManager
    {
        return $this->cache;
    }

    public function getMail(): MailManager
    {
        return $this->mail;
    }

    public function getLogger(): Logger
    {
        return $this->logger;
    }

    public function getRouter(): Router
    {
        return $this->router;
    }

    private function handleException(\Exception $e): void
    {
        $this->logger->error($e->getMessage(), [
            'file' => $e->getFile(),
            'line' => $e->getLine(),
            'trace' => $e->getTraceAsString(),
        ]);

        http_response_code(500);
        
        if ($this->config['app']['debug']) {
            echo json_encode([
                'error' => 'Error interno del servidor',
                'message' => $e->getMessage(),
                'file' => $e->getFile(),
                'line' => $e->getLine(),
                'trace' => $e->getTrace(),
            ]);
        } else {
            echo json_encode([
                'error' => 'Error interno del servidor',
                'message' => 'Por favor, contacte al administrador',
            ]);
        }
    }
}
EOF

# 5. Crear migraciones de base de datos
cat > database/migrations/001_create_companies_table.php << 'EOF'
<?php

use Sistema\Core\Database\Migration;

class CreateCompaniesTable extends Migration
{
    public function up()
    {
        $sql = "
        CREATE TABLE companies (
            id INT AUTO_INCREMENT PRIMARY KEY,
            name VARCHAR(200) NOT NULL,
            rif VARCHAR(20) NOT NULL UNIQUE,
            phone VARCHAR(20),
            email VARCHAR(100),
            address TEXT,
            base_currency ENUM('VES', 'USD', 'EUR') DEFAULT 'USD',
            logo VARCHAR(255),
            is_active BOOLEAN DEFAULT TRUE,
            settings JSON,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            INDEX idx_rif (rif),
            INDEX idx_active (is_active)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ";
        
        $this->execute($sql);
    }

    public function down()
    {
        $this->execute("DROP TABLE IF EXISTS companies");
    }
}
EOF

cat > database/migrations/002_create_branches_table.php << 'EOF'
<?php

use Sistema\Core\Database\Migration;

class CreateBranchesTable extends Migration
{
    public function up()
    {
        $sql = "
        CREATE TABLE branches (
            id INT AUTO_INCREMENT PRIMARY KEY,
            company_id INT NOT NULL,
            name VARCHAR(200) NOT NULL,
            code VARCHAR(50) UNIQUE,
            phone VARCHAR(20),
            email VARCHAR(100),
            address TEXT,
            manager_id INT,
            is_active BOOLEAN DEFAULT TRUE,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE,
            INDEX idx_company (company_id),
            INDEX idx_active (is_active),
            INDEX idx_code (code)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ";
        
        $this->execute($sql);
    }

    public function down()
    {
        $this->execute("DROP TABLE IF EXISTS branches");
    }
}
EOF

cat > database/migrations/003_create_exchange_rates_table.php << 'EOF'
<?php

use Sistema\Core\Database\Migration;

class CreateExchangeRatesTable extends Migration
{
    public function up()
    {
        $sql = "
        CREATE TABLE exchange_rates (
            id INT AUTO_INCREMENT PRIMARY KEY,
            date DATE NOT NULL UNIQUE,
            usd_to_ves DECIMAL(12,4) NOT NULL,
            eur_to_ves DECIMAL(12,4) NOT NULL,
            eur_to_usd DECIMAL(12,4) NOT NULL,
            registered_by INT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_date (date),
            INDEX idx_registered (registered_by)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ";
        
        $this->execute($sql);
    }

    public function down()
    {
        $this->execute("DROP TABLE IF EXISTS exchange_rates");
    }
}
EOF

# Continuar con más migraciones...

# 6. Crear frontend Vue.js
cat > resources/assets/js/app.js << 'EOF'
import { createApp } from 'vue'
import { createPinia } from 'pinia'
import { createRouter, createWebHistory } from 'vue-router'
import PrimeVue from 'primevue/config'
import ToastService from 'primevue/toastservice'
import ConfirmationService from 'primevue/confirmationservice'
import Tooltip from 'primevue/tooltip'

import App from './App.vue'
import Dashboard from './views/Dashboard.vue'
import Companies from './views/Companies.vue'
import Sales from './views/Sales.vue'
import Expenses from './views/Expenses.vue'
import Invoices from './views/Invoices.vue'
import Users from './views/Users.vue'
import Audit from './views/Audit.vue'
import Settings from './views/Settings.vue'

import 'primevue/resources/themes/lara-light-blue/theme.css'
import 'primevue/resources/primevue.min.css'
import 'primeicons/primeicons.css'
import './css/app.css'

const routes = [
    { path: '/', name: 'dashboard', component: Dashboard, meta: { requiresAuth: true } },
    { path: '/companies', name: 'companies', component: Companies, meta: { requiresAuth: true, permission: 'manage_companies' } },
    { path: '/sales', name: 'sales', component: Sales, meta: { requiresAuth: true, permission: 'manage_sales' } },
    { path: '/expenses', name: 'expenses', component: Expenses, meta: { requiresAuth: true, permission: 'manage_expenses' } },
    { path: '/invoices', name: 'invoices', component: Invoices, meta: { requiresAuth: true, permission: 'manage_invoices' } },
    { path: '/users', name: 'users', component: Users, meta: { requiresAuth: true, permission: 'manage_users' } },
    { path: '/audit', name: 'audit', component: Audit, meta: { requiresAuth: true, permission: 'view_audit' } },
    { path: '/settings', name: 'settings', component: Settings, meta: { requiresAuth: true } },
    { path: '/login', name: 'login', component: () => import('./views/Login.vue') },
]

const router = createRouter({
    history: createWebHistory(),
    routes,
})

router.beforeEach((to, from, next) => {
    const authStore = useAuthStore()
    
    if (to.meta.requiresAuth && !authStore.isAuthenticated) {
        next({ name: 'login' })
    } else if (to.meta.permission && !authStore.hasPermission(to.meta.permission)) {
        next({ name: 'dashboard' })
    } else {
        next()
    }
})

const app = createApp(App)
const pinia = createPinia()

app.use(pinia)
app.use(router)
app.use(PrimeVue)
app.use(ToastService)
app.use(ConfirmationService)
app.directive('tooltip', Tooltip)

app.mount('#app')
EOF

# 7. Crear componentes Vue principales
cat > resources/assets/js/App.vue << 'EOF'
<template>
  <div id="app" :class="{'sidebar-collapsed': sidebarCollapsed}">
    <Toast position="top-right" />
    <ConfirmDialog />
    
    <AppHeader @toggle-sidebar="toggleSidebar" />
    
    <div class="app-container">
      <AppSidebar :collapsed="sidebarCollapsed" />
      
      <main class="main-content">
        <div class="content-header">
          <Breadcrumb :home="home" :model="breadcrumbs" />
        </div>
        
        <div class="content-body">
          <router-view v-slot="{ Component }">
            <transition name="fade" mode="out-in">
              <component :is="Component" />
            </transition>
          </router-view>
        </div>
      </main>
    </div>
    
    <AppFooter />
  </div>
</template>

<script setup>
import { ref, computed, watch } from 'vue'
import { useRoute } from 'vue-router'
import { useAppStore } from '@/stores/app'
import AppHeader from './components/layout/AppHeader.vue'
import AppSidebar from './components/layout/AppSidebar.vue'
import AppFooter from './components/layout/AppFooter.vue'
import Breadcrumb from 'primevue/breadcrumb'

const route = useRoute()
const appStore = useAppStore()
const sidebarCollapsed = ref(false)

const home = ref({
  icon: 'pi pi-home',
  to: '/'
})

const breadcrumbs = computed(() => {
  const routeName = route.name
  const meta = route.meta
  
  let crumbs = []
  
  if (routeName !== 'dashboard') {
    crumbs.push({
      label: meta.title || routeName.charAt(0).toUpperCase() + routeName.slice(1),
      to: route.path
    })
  }
  
  return crumbs
})

const toggleSidebar = () => {
  sidebarCollapsed.value = !sidebarCollapsed.value
  appStore.setSidebarCollapsed(sidebarCollapsed.value)
}

watch(() => route.path, () => {
  // Cerrar sidebar en móviles al navegar
  if (window.innerWidth < 768) {
    sidebarCollapsed.value = true
  }
})
</script>

<style lang="scss">
#app {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
  background: var(--surface-ground);
  
  &.sidebar-collapsed {
    .app-sidebar {
      width: 60px;
      
      .menu-label {
        display: none;
      }
      
      .menu-item {
        justify-content: center;
      }
    }
    
    .main-content {
      margin-left: 60px;
    }
  }
}

.app-container {
  display: flex;
  flex: 1;
}

.main-content {
  flex: 1;
  margin-left: 250px;
  transition: margin-left 0.3s ease;
  padding: 1rem;
  overflow-y: auto;
  max-height: calc(100vh - 60px);
}

.content-header {
  background: var(--surface-card);
  border-radius: 12px;
  padding: 1rem;
  margin-bottom: 1rem;
  box-shadow: 0 2px 4px rgba(0,0,0,0.05);
}

.content-body {
  background: var(--surface-card);
  border-radius: 12px;
  padding: 1.5rem;
  box-shadow: 0 2px 4px rgba(0,0,0,0.05);
}

.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.3s ease;
}

.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

@media (max-width: 768px) {
  .main-content {
    margin-left: 0 !important;
    padding: 0.5rem;
  }
  
  .content-body {
    padding: 1rem;
  }
}
</style>
EOF

# 8. Crear Dashboard Vue
cat > resources/assets/js/views/Dashboard.vue << 'EOF'
<template>
  <div class="dashboard">
    <div class="dashboard-header">
      <h1 class="title">📊 Dashboard</h1>
      <div class="header-actions">
        <Calendar v-model="dateRange" selectionMode="range" :manualInput="false" />
        <Button label="Actualizar" icon="pi pi-refresh" @click="refreshData" />
      </div>
    </div>

    <!-- Tasas de Cambio -->
    <div class="exchange-rates-card">
      <div class="card-header">
        <h3>💱 Tasas de Cambio</h3>
        <Button label="Registrar Tasa" icon="pi pi-plus" severity="success" @click="showRateModal = true" />
      </div>
      <div class="rates-grid">
        <div class="rate-item">
          <div class="rate-label">USD → VES</div>
          <div class="rate-value">{{ formatCurrency(exchangeRates.usd_to_ves, 'VES') }}</div>
          <div class="rate-change" :class="getChangeClass(exchangeRates.usd_change)">
            {{ formatChange(exchangeRates.usd_change) }}
          </div>
        </div>
        <div class="rate-item">
          <div class="rate-label">EUR → VES</div>
          <div class="rate-value">{{ formatCurrency(exchangeRates.eur_to_ves, 'VES') }}</div>
          <div class="rate-change" :class="getChangeClass(exchangeRates.eur_change)">
            {{ formatChange(exchangeRates.eur_change) }}
          </div>
        </div>
        <div class="rate-item">
          <div class="rate-label">EUR → USD</div>
          <div class="rate-value">{{ formatNumber(exchangeRates.eur_to_usd, 4) }}</div>
        </div>
        <div class="rate-item">
          <div class="rate-label">Devaluación Mensual</div>
          <div class="rate-value text-danger">{{ formatPercent(devaluation) }}</div>
        </div>
      </div>
    </div>

    <!-- Métricas Principales -->
    <div class="metrics-grid">
      <MetricCard 
        title="Ventas del Mes" 
        :value="metrics.sales_month" 
        currency="USD"
        :change="metrics.sales_change"
        icon="pi pi-chart-line"
        color="primary"
      />
      <MetricCard 
        title="Gastos del Mes" 
        :value="metrics.expenses_month" 
        currency="USD"
        :change="metrics.expenses_change"
        icon="pi pi-money-bill"
        color="danger"
      />
      <MetricCard 
        title="Balance Actual" 
        :value="metrics.balance" 
        currency="USD"
        :change="metrics.balance_change"
        icon="pi pi-wallet"
        color="success"
      />
      <MetricCard 
        title="Empresas Activas" 
        :value="metrics.active_companies" 
        :change="metrics.companies_change"
        icon="pi pi-building"
        color="warning"
      />
    </div>

    <!-- Gráficos -->
    <div class="charts-grid">
      <div class="chart-card">
        <div class="card-header">
          <h4>📈 Ventas por Mes (USD)</h4>
          <Dropdown v-model="selectedPeriod" :options="periods" optionLabel="label" />
        </div>
        <Chart type="line" :data="salesChartData" :options="chartOptions" />
      </div>
      
      <div class="chart-card">
        <div class="card-header">
          <h4>🧾 Ventas vs Gastos</h4>
        </div>
        <Chart type="bar" :data="expensesChartData" :options="chartOptions" />
      </div>
    </div>

    <!-- Actividad Reciente -->
    <div class="activity-card">
      <div class="card-header">
        <h4>🔄 Actividad Reciente</h4>
      </div>
      <DataTable :value="recentActivity" :paginator="true" :rows="5">
        <Column field="time" header="Hora">
          <template #body="{ data }">
            {{ formatTime(data.time) }}
          </template>
        </Column>
        <Column field="user" header="Usuario" />
        <Column field="action" header="Acción" />
        <Column field="entity" header="Entidad" />
        <Column field="details" header="Detalles">
          <template #body="{ data }">
            <Tag :value="data.details" :severity="getSeverity(data.action)" />
          </template>
        </Column>
      </DataTable>
    </div>

    <!-- Modal para tasas -->
    <Dialog v-model:visible="showRateModal" header="Registrar Tasa de Cambio" :modal="true">
      <ExchangeRateForm @saved="handleRateSaved" @cancel="showRateModal = false" />
    </Dialog>
  </div>
</template>

<script setup>
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import { useDashboardStore } from '@/stores/dashboard'
import MetricCard from '@/components/dashboard/MetricCard.vue'
import ExchangeRateForm from '@/components/exchange/ExchangeRateForm.vue'
import Chart from 'primevue/chart'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Tag from 'primevue/tag'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import Calendar from 'primevue/calendar'
import Dropdown from 'primevue/dropdown'

const toast = useToast()
const dashboardStore = useDashboardStore()

const dateRange = ref([new Date(), new Date()])
const showRateModal = ref(false)
const selectedPeriod = ref({ label: 'Últimos 6 meses', value: 6 })

const periods = [
  { label: 'Último mes', value: 1 },
  { label: 'Últimos 3 meses', value: 3 },
  { label: 'Últimos 6 meses', value: 6 },
  { label: 'Último año', value: 12 }
]

const exchangeRates = computed(() => dashboardStore.exchangeRates)
const metrics = computed(() => dashboardStore.metrics)
const recentActivity = computed(() => dashboardStore.recentActivity)
const devaluation = computed(() => dashboardStore.devaluation)

const salesChartData = computed(() => ({
  labels: dashboardStore.salesChartLabels,
  datasets: [{
    label: 'Ventas (USD)',
    data: dashboardStore.salesChartData,
    borderColor: '#4361ee',
    backgroundColor: 'rgba(67, 97, 238, 0.1)',
    borderWidth: 2,
    tension: 0.4,
    fill: true
  }]
}))

const expensesChartData = computed(() => ({
  labels: dashboardStore.expensesChartLabels,
  datasets: [
    {
      label: 'Ventas',
      data: dashboardStore.expensesChartSales,
      backgroundColor: '#10b981'
    },
    {
      label: 'Gastos',
      data: dashboardStore.expensesChartExpenses,
      backgroundColor: '#ef4444'
    }
  ]
}))

const chartOptions = {
  responsive: true,
  maintainAspectRatio: false,
  plugins: {
    legend: {
      position: 'top',
    }
  },
  scales: {
    y: {
      beginAtZero: true,
      ticks: {
        callback: function(value) {
          return '$' + value.toLocaleString()
        }
      }
    }
  }
}

onMounted(async () => {
  await loadDashboardData()
})

async function loadDashboardData() {
  try {
    await dashboardStore.loadDashboardData()
  } catch (error) {
    toast.add({
      severity: 'error',
      summary: 'Error',
      detail: 'No se pudo cargar los datos del dashboard',
      life: 3000
    })
  }
}

async function refreshData() {
  await loadDashboardData()
  toast.add({
    severity: 'success',
    summary: 'Actualizado',
    detail: 'Datos del dashboard actualizados',
    life: 2000
  })
}

function handleRateSaved() {
  showRateModal.value = false
  loadDashboardData()
}

function formatCurrency(value, currency) {
  const formatter = new Intl.NumberFormat('es-VE', {
    style: 'currency',
    currency: currency === 'USD' ? 'USD' : 'VES',
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  })
  return formatter.format(value || 0)
}

function formatNumber(value, decimals = 2) {
  return Number(value || 0).toLocaleString('es-VE', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals
  })
}

function formatPercent(value) {
  return `${value >= 0 ? '+' : ''}${formatNumber(value, 1)}%`
}

function formatChange(value) {
  return value >= 0 ? `+${formatNumber(value, 2)}%` : `${formatNumber(value, 2)}%`
}

function getChangeClass(value) {
  return value >= 0 ? 'positive' : 'negative'
}

function getSeverity(action) {
  const severityMap = {
    'created': 'success',
    'updated': 'info',
    'deleted': 'danger',
    'login': 'info',
    'logout': 'warning'
  }
  return severityMap[action] || 'info'
}

function formatTime(time) {
  return new Date(time).toLocaleTimeString('es-VE', {
    hour: '2-digit',
    minute: '2-digit'
  })
}
</script>

<style lang="scss" scoped>
.dashboard {
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
}

.dashboard-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 1rem;

  .title {
    margin: 0;
    font-size: 1.75rem;
    font-weight: 700;
    color: var(--surface-900);
  }

  .header-actions {
    display: flex;
    gap: 1rem;
    align-items: center;
  }
}

.exchange-rates-card {
  background: var(--surface-card);
  border-radius: 12px;
  padding: 1.5rem;
  box-shadow: 0 2px 8px rgba(0,0,0,0.05);

  .card-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 1.5rem;

    h3 {
      margin: 0;
      font-size: 1.25rem;
      font-weight: 600;
    }
  }

  .rates-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 1rem;

    .rate-item {
      background: var(--surface-50);
      border-radius: 8px;
      padding: 1rem;
      text-align: center;
      border: 1px solid var(--surface-200);
      transition: all 0.3s;

      &:hover {
        transform: translateY(-2px);
        box-shadow: 0 4px 12px rgba(0,0,0,0.1);
      }

      .rate-label {
        font-size: 0.875rem;
        color: var(--surface-600);
        margin-bottom: 0.5rem;
      }

      .rate-value {
        font-size: 1.5rem;
        font-weight: 700;
        color: var(--surface-900);
        margin-bottom: 0.5rem;
      }

      .rate-change {
        font-size: 0.875rem;
        font-weight: 600;

        &.positive {
          color: var(--green-500);
        }

        &.negative {
          color: var(--red-500);
        }
      }
    }
  }
}

.metrics-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
  gap: 1rem;
}

.charts-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(500px, 1fr));
  gap: 1rem;

  @media (max-width: 1200px) {
    grid-template-columns: 1fr;
  }
}

.chart-card {
  background: var(--surface-card);
  border-radius: 12px;
  padding: 1.5rem;
  box-shadow: 0 2px 8px rgba(0,0,0,0.05);

  .card-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 1.5rem;

    h4 {
      margin: 0;
      font-size: 1.125rem;
      font-weight: 600;
    }
  }

  canvas {
    height: 300px !important;
  }
}

.activity-card {
  background: var(--surface-card);
  border-radius: 12px;
  padding: 1.5rem;
  box-shadow: 0 2px 8px rgba(0,0,0,0.05);

  .card-header {
    margin-bottom: 1.5rem;

    h4 {
      margin: 0;
      font-size: 1.125rem;
      font-weight: 600;
    }
  }
}

.text-danger {
  color: var(--red-500) !important;
}
</style>
EOF

echo "✅ Instalación de aplicación completada!"
echo ""
echo "Para continuar:"
echo "1. Ejecutar migraciones: cd ${APP_DIR} && php app/console migrate"
echo "2. Construir frontend: cd ${APP_DIR} && npm run build"
echo "3. Acceder a: http://localhost"
