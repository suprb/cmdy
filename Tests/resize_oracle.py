"""Retain generated Python expectations for CPU-only Swift cross-checks."""
import argparse
import json
from pathlib import Path
from resize_protocol import GRIDS, digest, history, row_word, visible_row, row_classes, cell_classes_bytes

def make_oracle():
    values = []
    for nonce, sequence in (("0123456789abcdef0123456789abcdef", 5), ("0" * 32, 0), ("f" * 32, 0xffffffff)):
        for columns, rows in GRIDS:
            visible = b"\r\n".join(visible_row(nonce, sequence, columns, rows, row) for row in range(rows)) + b"\r\n"
            values.append(dict(nonce=nonce, sequence=sequence, columns=columns, rows=rows,
                words=[row_word(nonce, sequence, columns, rows, row) for row in range(rows)],
                historySHA256=digest(history(nonce)), visibleSHA256=digest(visible),
                cellClasses=[row_classes(nonce, sequence, columns, rows, row) for row in range(rows)],
                cellClassesSHA256=digest(cell_classes_bytes(nonce, sequence, columns, rows))))
    return {"cases": values}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with args.output.open("x") as stream:
        json.dump(make_oracle(), stream, indent=2, sort_keys=True); stream.write("\n")
