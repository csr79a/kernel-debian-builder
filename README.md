# kernel-debian-builder

Instalador de Kernel csr79a — compila e instala automáticamente la última versión **estable** del kernel de Linux (vanilla, sin parches) en Debian y derivados, generando paquetes `.deb` gestionados por `dpkg`/`apt`, con interfaz interactiva por pantallas (`whiptail`).

## Qué hace

1. Instala las dependencias de compilación necesarias desde los repos oficiales de Debian (incluye `debhelper` y `libdw-dev`, requeridas por `bindeb-pkg` y `dwarves`).
2. Comprueba que hay al menos 20GB libres en disco antes de empezar.
3. Detecta si Secure Boot está activado y avisa del riesgo de arrancar un kernel sin firmar.
4. Detecta la última versión estable publicada en [kernel.org](https://kernel.org).
5. Calcula un número de jobs de compilación recomendado según tus hilos y RAM, y te deja elegir entre ese valor o usar todos los hilos.
6. Descarga el código fuente y verifica su integridad (SHA256).
7. Genera la configuración (`.config`) a partir del kernel que tienes corriendo actualmente.
8. Compila el kernel y genera paquetes `.deb` (`linux-image`, `linux-headers`) usando el método nativo del propio kernel (`make bindeb-pkg`).
9. Instala los paquetes con `dpkg`.
10. Regenera GRUB (`update-grub`).
11. Pregunta si quieres eliminar los archivos generados durante la compilación.
12. Pantalla final con opción de reiniciar ahora o después.

## Uso

**Si clonas el repo de GitHub:**

```bash
git clone https://github.com/csr79a/kernel-debian-builder.git
cd kernel-debian-builder
chmod +x build-kernel-debian.sh
./build-kernel-debian.sh
```

**Si descargaste los archivos sueltos** (por ejemplo desde `~/Descargas`), colócalos juntos en una carpeta antes de ejecutar:

```bash
mkdir -p ~/kernel-debian-builder
mv build-kernel-debian.sh README.md MANUAL.md ~/kernel-debian-builder/
cd ~/kernel-debian-builder
chmod +x build-kernel-debian.sh
./build-kernel-debian.sh
```

No lo ejecutes como root: el script pedirá `sudo` cuando lo necesite.

## Requisitos

- Debian (o derivado) con `sudo` configurado.
- Conexión a internet.
- Espacio en disco: al menos 20GB libres (el script lo comprueba antes de empezar).

Más detalles en [MANUAL.md](MANUAL.md).

## Notas

- Solo compila versiones **estables** (no `-rc`), siempre la última publicada.
- Si ya estás en la última versión estable, el script no hace nada.
- El kernel se instala con el sufijo `-custom` en `LOCALVERSION`, para distinguirlo fácilmente del kernel de los repos de Debian en el menú de GRUB.
- Desinstalar es tan sencillo como con cualquier paquete de Debian: `sudo apt remove linux-image-<version>-custom`.
- Si Secure Boot está activado, el kernel se instala igualmente pero no arrancará hasta firmarlo con una clave MOK propia — ver sección de Secure Boot en el MANUAL.
