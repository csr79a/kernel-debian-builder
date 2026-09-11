# MANUAL — kernel-debian-builder (Instalador de Kernel csr79a)

Versión actual: **1.1.3**.

## 1. Objetivo del proyecto

Automatizar el flujo completo de compilación de un kernel Linux vanilla en Debian: desde la descarga verificada del código fuente en kernel.org hasta tener el nuevo kernel arrancable desde GRUB, sin herramientas externas a los repos oficiales de Debian, con una interfaz de pantallas interactiva (`whiptail`).

## 2. Requisitos previos

- Debian o derivado (Trixie, Sid, etc.).
- Usuario con permisos de `sudo`.
- Al menos 50GB libres en disco (el script lo comprueba antes de empezar y aborta si no hay suficiente).
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
- `gnupg` (verificación de firma PGP)
- `xz-utils` (descomprimir el tarball para verificarlo contra la firma)

## 5. Flujo paso a paso

### 5.1. Pantalla de bienvenida

Muestra el nombre y versión del instalador, una descripción breve, y pide confirmación para continuar.

### 5.2. Comprobación de espacio en disco

Antes de descargar o compilar nada, el script comprueba que haya al menos 50GB libres en el directorio de trabajo (`~/kernel-build`). Si no los hay, se detiene inmediatamente con un mensaje claro, en vez de fallar a mitad de una compilación de 20-30 minutos.

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

El script consulta `https://www.kernel.org/releases.json` y extrae la versión marcada como `stable`, validando que el formato recibido sea el esperado (por si la API cambiara de forma inesperada). Compara esa versión contra `uname -r` con **igualdad exacta** (o como prefijo seguido de `.` o `-`), para evitar falsos positivos: por ejemplo, una versión objetivo `6.1` ya no se confunde con un kernel actual `6.12.5-custom` solo porque coincidan los primeros caracteres. Si ya estás corriendo la versión estable más reciente, el script termina sin hacer nada.

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

### 5.6. Descarga y verificación de integridad (SHA256)

Descarga el `.tar.xz` desde `cdn.kernel.org` y verifica su suma SHA256 contra el fichero de sumas oficial publicado junto a cada release. Si la verificación falla, el script se detiene inmediatamente.

### 5.7. Verificación de autenticidad (firma PGP)

El SHA256 anterior protege contra corrupción de descarga, pero se obtiene del mismo servidor que el propio tarball: si un mirror estuviera comprometido, en teoría podría servir tarball y checksum falsos a la vez. La firma PGP añade una capa de autenticidad independiente:

1. El script importa las claves oficiales de **Linus Torvalds** y **Greg Kroah-Hartman** (huellas ancladas explícitamente en el script, no se confía en el "web of trust" de gpg), probando tres fuentes en orden: `keyserver.ubuntu.com`, `keys.openpgp.org` y, como último recurso, el **WKD de kernel.org** (`gpg --locate-keys torvalds@kernel.org gregkh@kernel.org`, el método que la propia kernel.org documenta como oficial en `kernel.org/signature.html`).
2. Descarga la firma `.tar.sign` correspondiente y la verifica contra el tarball descomprimido (`xz -cd | gpg --verify`), que es el método exacto que documenta kernel.org.
3. Comprueba que la firma provenga de una de las huellas ancladas — una firma criptográficamente válida pero de una clave no reconocida también se rechaza.
4. El llavero PGP se mantiene aislado en `~/kernel-build/.gnupg-kernel`, sin tocar el `~/.gnupg` real del usuario.

Si cualquiera de estos pasos falla, el script se detiene sin compilar.

### 5.8. Configuración (.config)

Copia `/boot/config-$(uname -r)` (la configuración del kernel que tienes corriendo ahora mismo) y ejecuta `make olddefconfig`, que adapta esa configuración a las nuevas opciones de la versión más reciente, minimizando el riesgo de perder soporte de hardware o módulos que ya usas.

A continuación, fuerza explícitamente las opciones de hardware ASUS (`CONFIG_ASUS_WMI`, `CONFIG_ASUS_ARMOURY`, `CONFIG_FIRMWARE_ATTRIBUTES_CLASS`, `CONFIG_ASUS_NB_WMI`, `CONFIG_HID_ASUS`), por si la config heredada las tuviera desactivadas (por ejemplo, por haber arrancado alguna vez un kernel de serie sin esas opciones activas). Sin este paso, esa ausencia se propagaría de build en build.

### 5.9. Compilación

```bash
make -j$JOBS bindeb-pkg LOCALVERSION=-custom
```

`bindeb-pkg` es el target oficial del propio kernel Linux para generar paquetes `.deb`. El sufijo `-custom` permite distinguir este kernel de los que vienen de los repos de Debian. El log completo de la compilación se guarda en `~/kernel-build/build-<version>.log`.

### 5.10. Instalación

Los `.deb` generados se instalan con `sudo apt install` (no `dpkg -i`), para que si al kernel nuevo le faltara alguna dependencia, apt la resuelva e instale automáticamente en vez de dejar el sistema con paquetes a medio instalar. Antes de instalar, el script comprueba que efectivamente se hayan generado los paquetes esperados (`linux-image-*` y `linux-headers-*`).

### 5.11. GRUB

El script ejecuta `sudo update-grub` de forma explícita al final de la instalación.

### 5.12. Limpieza de archivos

Pregunta si quieres eliminar el contenido de `~/kernel-build` (fuente descargada, código extraído, `.deb` generados). Si dices que no, se conservan por si quieres reinstalarlos o revisar el log.

### 5.13. Pantalla final y reinicio

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
- No hay verificación de que el módulo DKMS de NVIDIA se haya reconstruido correctamente para el kernel nuevo antes de reiniciar (pendiente de añadir).
- Pensado para Debian; en otras distros basadas en `.deb` debería funcionar igual, pero no está probado.

## 8. Historial de versiones

- **1.1.3** — Se añade el WKD de kernel.org (resuelto por HTTPS contra su propio dominio) como tercera fuente para importar las claves PGP, por si ambos keyservers estuvieran caídos a la vez.
- **1.1.2** — Se usa `apt install` en vez de `dpkg -i` para instalar los paquetes `.deb` generados, resolviendo dependencias automáticamente en vez de dejar el sistema a medias.
- **1.1.1** — Corrección de bugs menores: comprobación de `sudo`, falso positivo al detectar el kernel ya instalado, protección del glob al instalar los `.deb`, manejo de error en la consulta a kernel.org y validación del formato de versión recibido. Se añade verificación de firma PGP (autenticidad, además del SHA256 ya existente) contra las claves oficiales de kernel.org.
- **1.1.0** — Versión base: descarga desde kernel.org, verificación SHA256, compilación con opciones ASUS forzadas, generación e instalación de paquetes `.deb`, regeneración de GRUB.
