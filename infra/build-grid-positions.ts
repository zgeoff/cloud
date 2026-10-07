interface GridPosition {
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
}

// panels flow left to right in rows of 24 columns
export function buildGridPositions(
  panels: readonly { readonly width: number; readonly height: number }[],
): GridPosition[] {
  let x = 0;
  let y = 0;
  let rowHeight = 0;

  return panels.map((panel) => {
    if (x + panel.width > 24) {
      x = 0;
      y += rowHeight;
      rowHeight = 0;
    }

    const position = { x, y, w: panel.width, h: panel.height };

    x += panel.width;
    rowHeight = Math.max(rowHeight, panel.height);

    return position;
  });
}
