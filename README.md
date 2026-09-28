# Kernel Builder GUI

Interfaz gráfica PyQt6 para `build-kernel-debian.sh`.

## Qué añade

- Selección visual de arquitectura de CPU:
  - Genérico
  - x86-64-v3 (solo si GCC lo admite)
  - AMD Zen 3 / znver3 (solo si la CPU y GCC son compatibles)
- Opción visual para activar BORE.
- Resumen de configuración antes de compilar.
- Mantiene `build-kernel-debian.sh` como motor real de descarga, verificación, parches, configuración, compilación e instalación.
- La GUI no aplica directamente los parches: transmite la selección al script mediante variables de entorno.
- `--force` sigue disponible.
- El puente gráfico de whiptail sigue funcionando para los diálogos que todavía pertenecen al flujo del script.

## Requisitos

```bash
sudo apt install python3 python3-pyqt6
```

El script también necesita sus propias dependencias habituales.

## Ejecutar

Los dos archivos deben permanecer juntos:

```bash
chmod +x build-kernel-debian.sh kernel_builder_gui.py
./kernel_builder_gui.py
```

## Seguridad / funcionamiento

La GUI no sustituye la lógica del script. Solo envía:

- `KBUILDER_MARCH_CHOICE=generic|v3|znver3`
- `KBUILDER_BORE_CHOICE=yes|no`

Si se ejecuta `build-kernel-debian.sh` directamente desde una terminal, estas variables pueden no existir y el flujo interactivo original se mantiene.