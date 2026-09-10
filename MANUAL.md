# MANUAL — kernel-debian-builder (Instalador de Kernel csr79a)

## 1. Objetivo del proyecto

Automatizar el flujo completo de compilación de un kernel Linux vanilla en Debian: desde la descarga del código fuente en kernel.org hasta tener el nuevo kernel arrancable desde GRUB, sin herramientas externas a los repos oficiales de Debian, con una interfaz de pantallas interactiva (`whiptail`).

## 2. Requisitos previos

- Debian o derivado (Trixie, Sid, etc.).
- Usuario con permisos de `sudo`.
- Al menos 20GB libres en disco (el script lo comprueba antes de empezar y aborta si no hay suficiente).
- Conexión a internet.

## 3. Preparar los archivos

Si descargaste `build-kernel-debian.sh`, `README.md` y `MANUAL.md` sueltos (no vía `git clone`), primero muévelos juntos a una carpeta y da permisos de ejecución al script:

```bash
mkdir -p ~/kernel-debian-builder
mv build-kernel-debian.sh README.md MANUAL.md ~/kernel-debian-builder/
cd ~/kernel-debian-builder
chmod +x build-kernel-debian.sh
```

Sin `chmod +x`, `./build-kernel-debian.sh` fallará con "Permiso denegado".

## 4. Qué instala el script

Paquetes desde los repos oficiales de Debian:

- `build-essential`
- `libncurses-dev`
- `bison`
- `flex`
- `libssl-dev`
- `libelf-dev`
- `dwarves` (necesario para generar información BTF)
- `libdw-dev` (requerida por `dwarves`/`pahole`)
- `debhelper` (provee `debhelper-compat`, exigido por `make bindeb-pkg`)
- `fakeroot`
- `bc`
- `rsync`
- `curl`
- `jq`
- `whiptail` (interfaz de pantallas)
- `mokutil` (detección de Secure Boot)

## 5. Flujo paso a paso

### 5.1. Pantalla de bienvenida

Muestra el nombre y versión del instalador, una descripción breve, y pide confirmación para continuar.

### 5.2. Comprobación de espacio en disco

Antes de descargar o compilar nada, el script comprueba que haya al menos 20GB libres en el directorio de trabajo (`~/kernel-build`). Si no los hay, se detiene inmediatamente con un mensaje claro, en vez de fallar a mitad de una compilación de 20-30 minutos.

### 5.3. Detección de Secure Boot

El script ejecuta `mokutil --sb-state`:

- **Si está desactivado**: continúa sin más, sin preguntar nada.
- **Si está activado**: avisa de que el kernel compilado no estará firmado y de que UEFI podría rechazar arrancarlo, y pregunta si quieres continuar de todas formas.

**Si decides seguir con Secure Boot activado**, para que el kernel arranque tendrás que firmarlo manualmente con una clave propia (MOK — Machine Owner Key), un proceso de una sola vez:

```bash
# 1. Generar una clave propia (una sola vez en la vida del sistema)
sudo openssl req -new -x509 -newkey rsa:2048 -keyout MOK.priv -outform DER -out MOK.der -nodes -days 36500 -subj "/CN=Mi Clave Kernel/"

# 2. Registrarla en el firmware UEFI (pide una contraseña temporal)
sudo mokutil --import MOK.der

# 3. Al reiniciar, aparece una pantalla azul de MokManager donde hay que
#    elegir "Enroll MOK" e introducir esa contraseña para confirmar

# 4. Con la clave ya inscrita, firmar el kernel compilado
sudo /usr/lib/linux-kbuild-<version>/scripts/sign-file sha256 MOK.priv MOK.der /boot/vmlinuz-<version>-custom
```

El paso 3 requiere interacción física en el arranque y no se puede automatizar desde el script.

### 5.4. Detección de versión

El script consulta `https://www.kernel.org/releases.json` y extrae la versión marcada como `stable`. Si ya estás corriendo esa versión, el script termina sin hacer nada.

### 5.5. Cálculo de jobs de compilación

El script detecta tus hilos (`nproc`) y tu RAM total (`free`), y calcula un valor recomendado con la fórmula:

```
jobs_recomendados = mínimo( hilos_detectados , (RAM_GB - 2) / 2 )
```

Se reservan 2GB fijos para el sistema antes de repartir el resto entre los jobs, asumiendo un pico de hasta ~2GB por proceso de compilación en paralelo. Te muestra ambos datos (hilos y RAM) y el valor recomendado, y te deja elegir entre usarlo o forzar el uso de todos los hilos disponibles (con un aviso si eso supera lo recomendado para tu RAM).

Ejemplos:

| RAM  | Hilos | Jobs recomendados |
|------|-------|--------------------|
| 32GB | 16    | 15                 |
| 16GB | 8     | 7                  |
| 8GB  | 16    | 3                  |

### 5.6. Descarga y verificación

Descarga el `.tar.xz` desde `cdn.kernel.org` y verifica su suma SHA256 contra el fichero de sumas oficial publicado junto a cada release. Si la verificación falla, el script se detiene inmediatamente.

### 5.7. Configuración (.config)

Copia `/boot/config-$(uname -r)` (la configuración del kernel que tienes corriendo ahora mismo) y ejecuta `make olddefconfig`, que adapta esa configuración a las nuevas opciones de la versión más reciente, minimizando el riesgo de perder soporte de hardware o módulos que ya usas.

### 5.8. Compilación

```bash
make -j$JOBS bindeb-pkg LOCALVERSION=-custom
```

`bindeb-pkg` es el target oficial del propio kernel Linux para generar paquetes `.deb`. El sufijo `-custom` permite distinguir este kernel de los que vienen de los repos de Debian. El log completo de la compilación se guarda en `~/kernel-build/build-<version>.log`.

### 5.9. Instalación

Los `.deb` generados se instalan con `dpkg -i`, quedando registrados en el sistema de paquetes de Debian como cualquier otro paquete.

### 5.10. GRUB

El script ejecuta `sudo update-grub` de forma explícita al final de la instalación.

### 5.11. Limpieza de archivos

Pregunta si quieres eliminar el contenido de `~/kernel-build` (fuente descargada, código extraído, `.deb` generados). Si dices que no, se conservan por si quieres reinstalarlos o revisar el log.

### 5.12. Pantalla final y reinicio

Muestra un resumen de la versión instalada (con nota sobre Secure Boot si aplica) y ofrece reiniciar ahora o después. El nuevo kernel no estará activo hasta que reinicies.

## 6. Desinstalar un kernel compilado

Al quedar gestionado como un paquete Debian normal, basta con:

```bash
sudo apt remove linux-image-<version>-custom linux-headers-<version>-custom
sudo update-grub
```

## 7. Limitaciones actuales / posibles mejoras futuras

- Por ahora solo soporta kernel **vanilla** (sin parches). Podría añadirse en el futuro un paso opcional para aplicar parches sueltos (p. ej. schedulers alternativos) sobre la base vanilla.
- La firma automática con clave MOK para Secure Boot no está implementada todavía — de momento es un proceso manual documentado arriba.
- Pensado para Debian; en otras distros basadas en `.deb` debería funcionar igual, pero no está probado.
