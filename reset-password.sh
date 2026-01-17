#!/bin/bash
# Reset de contraseña de administrador

read -sp "Nueva contraseña para admin: " PASSWORD
echo

HASH=$(php -r "echo password_hash('$PASSWORD', PASSWORD_BCRYPT);")

mysql -u root -pContraseñaRootSegura123 sistema_gestion << EOF
UPDATE users 
SET password = '$HASH', 
    updated_at = NOW()
WHERE email = 'admin@sistema.local' 
   OR username = 'admin';
EOF

echo "✅ Contraseña actualizada exitosamente"
