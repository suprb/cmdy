import {
  type CSSProperties,
  type HTMLAttributes,
  type ReactNode,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState
} from "react";
import { EditorialText } from "./EditorialCase";

function classes(...values: Array<string | false | null | undefined>) {
  return values.filter(Boolean).join(" ");
}

export function SacredWindow({
  children,
  className,
  ...rest
}: HTMLAttributes<HTMLElement>) {
  return (
    <section className={classes("sacred-window", className)} {...rest}>
      {children}
    </section>
  );
}

type CardProps = Omit<HTMLAttributes<HTMLElement>, "title"> & {
  title?: ReactNode;
  mode?: "default" | "left" | "right";
};

export function SacredCard({
  children,
  className,
  mode = "default",
  title,
  ...rest
}: CardProps) {
  return (
    <article className={classes("sacred-card", `mode-${mode}`, className)} {...rest}>
      <header className="sacred-card-header">
        <span className="sacred-card-rule left" aria-hidden="true" />
        {title ? <h2 className="sacred-card-title">{title}</h2> : null}
        <span className="sacred-card-rule right" aria-hidden="true" />
      </header>
      <div className="sacred-card-body">{children}</div>
    </article>
  );
}

type ActionButtonProps = {
  ariaLabel?: string;
  children: ReactNode;
  className?: string;
  hotkey?: ReactNode;
  href?: string;
  isSelected?: boolean;
  onClick?: () => void;
  target?: string;
  title?: string;
  type?: "button" | "submit";
};

export function ActionButton({
  ariaLabel,
  children,
  className,
  hotkey,
  href,
  isSelected,
  onClick,
  target,
  title,
  type = "button"
}: ActionButtonProps) {
  const content = (
    <>
      {hotkey ? <span className="action-hotkey">{hotkey}</span> : null}
      <span className="action-content">{children}</span>
    </>
  );
  const rootClass = classes("action-button", isSelected && "selected", className);
  if (href) {
    return (
      <a aria-label={ariaLabel} className={rootClass} href={href} target={target} title={title} onClick={onClick}>
        {content}
      </a>
    );
  }
  return (
    <button aria-label={ariaLabel} aria-pressed={isSelected === undefined ? undefined : isSelected} className={rootClass} type={type} title={title} onClick={onClick}>
      {content}
    </button>
  );
}

export function SacredBadge({
  children,
  className,
  ...rest
}: HTMLAttributes<HTMLSpanElement>) {
  return (
    <span className={classes("sacred-badge", className)} {...rest}>
      {children}
    </span>
  );
}

interface SimpleTableProps {
  data: ReactNode[][];
  align?: Array<"left" | "right">;
  label?: string;
}

const statusOK = new Set(["ACTIVE", "OPEN", "APPROVED", "SHIPPED", "READY", "LIVE"]);
const statusOff = new Set(["CLOSED", "PAID", "SUSPENDED", "OFFLINE"]);

export function SimpleTable({ data, align, label }: SimpleTableProps) {
  if (!data.length) return null;
  const [header, ...rows] = data;
  const cellClass = (value: ReactNode, column: number) => {
    const status = typeof value === "string" ? value.toUpperCase() : "";
    return classes(
      align?.[column] === "right" && "align-right",
      statusOK.has(status) && "status-ok",
      statusOff.has(status) && "status-off"
    );
  };
  return (
    <div className="simple-table-scroll">
      <table className="simple-table" aria-label={label}>
        <thead>
          <tr>
            {header.map((cell, index) => (
              <th key={index} className={cellClass(cell, index)} scope="col">
                <EditorialText>{cell}</EditorialText>
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, rowIndex) => (
            <tr key={rowIndex} tabIndex={0}>
              {row.map((cell, columnIndex) => (
                <td key={columnIndex} className={cellClass(cell, columnIndex)}>
                  <EditorialText>{cell}</EditorialText>
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function RowSpaceBetween({
  children,
  className,
  ...rest
}: HTMLAttributes<HTMLElement>) {
  return (
    <section className={classes("row-space-between", className)} {...rest}>
      {children}
    </section>
  );
}

interface AccordionProps {
  children?: ReactNode;
  defaultValue?: boolean;
  title: string;
}

export function SacredAccordion({ children, defaultValue = false, title }: AccordionProps) {
  const [open, setOpen] = useState(defaultValue);
  const panelId = useId();
  return (
    <div className={classes("sacred-accordion", open && "open")}>
      <button
        aria-controls={panelId}
        aria-expanded={open}
        className="accordion-trigger"
        onClick={() => setOpen((value) => !value)}
        type="button"
      >
        <span aria-hidden="true">{open ? "▾" : "▸"}</span>
        <span>{title}</span>
      </button>
      {open ? <div className="accordion-body" id={panelId}>{children}</div> : null}
    </div>
  );
}

interface BarProgressProps {
  fillChar?: string;
  progress: number;
}

export function BarProgress({ fillChar = "░", progress }: BarProgressProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const measureRef = useRef<HTMLSpanElement>(null);
  const [containerWidth, setContainerWidth] = useState(0);
  const [characterWidth, setCharacterWidth] = useState(0);

  useLayoutEffect(() => {
    const width = measureRef.current?.getBoundingClientRect().width ?? 0;
    if (width > 0) setCharacterWidth(width);
  }, [fillChar]);

  useEffect(() => {
    if (!containerRef.current || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(([entry]) => setContainerWidth(entry.contentRect.width));
    observer.observe(containerRef.current);
    return () => observer.disconnect();
  }, []);

  const capped = Math.max(0, Math.min(progress, 100));
  const maximum = characterWidth && containerWidth
    ? Math.max(1, Math.floor(containerWidth / characterWidth))
    : 16;
  const filled = Math.round((capped / 100) * maximum);
  return (
    <div
      aria-valuemax={100}
      aria-valuemin={0}
      aria-valuenow={capped}
      className="bar-progress"
      ref={containerRef}
      role="progressbar"
    >
      <span className="bar-measure" ref={measureRef}>{fillChar}</span>
      {fillChar.repeat(filled)}
    </div>
  );
}

type TerminalInputProps = Omit<React.InputHTMLAttributes<HTMLInputElement>, "className"> & {
  label?: string;
  rootStyle?: CSSProperties;
};

export function TerminalInput({ id, label, rootStyle, ...rest }: TerminalInputProps) {
  const generatedID = useId();
  const inputID = id ?? generatedID;
  return (
    <label className="terminal-input" htmlFor={inputID} style={rootStyle}>
      {label ? <span className="terminal-input-label">{label}</span> : null}
      <span className="terminal-input-shell" aria-hidden="true">⌕</span>
      <input id={inputID} {...rest} />
    </label>
  );
}
