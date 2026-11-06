# omarchy-matrix

Modo de espacio de trabajo **matrix** para [Omarchy](https://omarchy.org): un layout de Hyprland con columnas que se desplazan en horizontal (como *scrolling*) y que además apilan varias ventanas, cada columna con su propio desplazamiento vertical. Se integra con Omarchy como un modo nativo más, junto a Tiling, Scrolling y Floating.

## Qué incluye

| Parte | Dónde queda | Qué hace |
|---|---|---|
| `hypr/omarchy-matrix.lua` | `~/.config/hypr/` | El layout `lua:matrix`, sus atajos y su integración con los modos de Omarchy (`o.workspace_mode`). |
| `plugins/matrix.frames` | `~/.config/omarchy/plugins/` | Servicio del shell: marco único alrededor del encabezado y la ventana, con nombre e icono de la app, RAM, y botones para mover y cerrar. |
| `plugins/matrix.layout-mode` | `~/.config/omarchy/plugins/` | Botón de la barra: muestra el modo del espacio de trabajo como teselas. Clic avanza, clic derecho retrocede; al pasar el puntero se rellena. |
| `bin/matrix-layout-default` | `~/.local/bin/` | Fija el layout por defecto, matrix incluido (los otros los pasa a Omarchy). |
| `bin/matrix-panel-mem` | `~/.local/bin/` | RAM de cada ventana para los encabezados (y de las apps de la VM de winpodx, si existe). |
| `menu/workspace-layout.jsonc` | `~/.config/omarchy/extensions/omarchy-menu.jsonc` | Appearance › Workspace Layout con la opción Matrix. |

## Integración con Omarchy

- **Modos de espacio de trabajo:** matrix es un modo más. Se guarda donde Omarchy guarda los suyos y lo reconocen `omarchy-hyprland-workspace-layout-current`, el dock y los menús.
  - `SUPER + L` recorre tiling → scrolling → floating → matrix.
  - `SUPER + ALT + L` va en sentido contrario.
- **Appearance › Workspace Layout:** permite elegir Matrix como layout por defecto.
  - Con [omarchy-menu-plus](../omarchy-menu-plus) instalado, las entradas usan las mismas teselas que el botón de la barra.
- **Opciones de ventana de Omarchy:** los marcos las siguen.
  - **Window Corners:** el redondeo se aplica a encabezado más ventana, y también al borde activo.
  - **Window Gaps:** se respetan los espacios entre ventanas.
  - **Glassy:** el encabezado se vuelve translúcido y con desenfoque.
  - **1-Window Ratio:** una columna sola mantiene la proporción y queda centrada.
  - **Colores:** los del borde y del tema.
  - **Animaciones:** los marcos se mueven con la misma curva y duración que las ventanas.

## Atajos en un espacio matrix

| Atajo | Acción |
|---|---|
| `SUPER + J` | Une a esta columna la ventana vecina más visible |
| `SUPER + SHIFT + J` | Saca la ventana a su propia columna |
| `SUPER + flechas` | Mueve el foco por la matriz |
| `SUPER + SHIFT + ←/→` | Saca la ventana de su columna o la pasa a la columna vecina |
| `SUPER + SHIFT + ↑/↓` | Mueve la ventana dentro de su columna |
| `SUPER + -/=` y arrastre con `SUPER` + clic derecho | Cambia el ancho de la columna y el alto de la ventana |
| `SUPER` + arrastre con clic izquierdo | Suelta la ventana en otra columna |
| Rueda sobre encabezados o huecos; deslizar con 3 dedos | Cambia de columna |

## Instalar

```bash
./install.sh
```

Se puede volver a ejecutar para actualizar.

## Desinstalar

```bash
./uninstall.sh
```

Los espacios de trabajo que estaban guardados en modo matrix vuelven al layout por defecto. Hasta cerrar la sesión de Hyprland pueden quedar en memoria algunos eventos del layout; no tienen efecto.

## Requisitos

Omarchy con configuración de Hyprland en Lua (`~/.config/hypr/hyprland.lua`), Hyprland 0.56 o superior y el shell de Omarchy (Quickshell).
